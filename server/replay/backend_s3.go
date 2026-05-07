package replay

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// S3Config holds the connection parameters for an S3-compatible backend.
// All fields except Bucket are optional — see field comments.
type S3Config struct {
	// Endpoint overrides the default AWS endpoint. Required for S3-compatible
	// services such as MinIO, Cloudflare R2, or GCS-via-S3. Leave empty to use
	// the standard AWS regional endpoint.
	Endpoint string

	// Region is the AWS / bucket region (e.g. "us-east-1"). Some S3-compatible
	// providers (MinIO, R2) accept any non-empty string.
	Region string

	// Bucket is the target bucket name (required).
	Bucket string

	// AccessKey and SecretKey are the static credentials. When both are empty,
	// the SDK falls back to the standard credential chain (env vars, EC2
	// metadata, etc.) which is appropriate for IAM-role-based deployments.
	AccessKey string
	SecretKey string

	// PathPrefix is an optional namespace prepended to every object key,
	// e.g. "prod/" or "staging/". If non-empty it should end with "/".
	PathPrefix string

	// UseSSL controls whether the endpoint uses HTTPS. Ignored for standard AWS
	// endpoints (always HTTPS). Set to false only for local MinIO dev/test.
	UseSSL bool
}

// S3Backend stores replay audit data in S3-compatible object storage.
// Object layout:
//
//	{prefix}{round_id}/manifest.json
//	{prefix}{round_id}/replay.bin
//
// Both objects carry metadata headers:
//
//	x-amz-meta-round-id: <decimal round_id>
//	x-amz-meta-sha256:   <hex digest of replay.bin>
type S3Backend struct {
	client *s3.Client
	cfg    S3Config
}

// NewS3Backend constructs an S3Backend and validates the configuration. It
// does not make any network calls; the first I/O happens on Save/Load.
func NewS3Backend(cfg S3Config) (*S3Backend, error) {
	if cfg.Bucket == "" {
		return nil, errors.New("replay: S3Config.Bucket is required")
	}

	awsCfg := aws.Config{
		Region: cfg.Region,
	}
	if cfg.Region == "" {
		awsCfg.Region = "us-east-1" // default; S3-compatible services often ignore it
	}

	// Static credentials override the default chain when provided.
	if cfg.AccessKey != "" || cfg.SecretKey != "" {
		awsCfg.Credentials = credentials.NewStaticCredentialsProvider(
			cfg.AccessKey, cfg.SecretKey, "",
		)
	}

	// Build client options.
	opts := []func(*s3.Options){
		func(o *s3.Options) {
			// Path-style addressing required for MinIO and most S3-compatibles.
			o.UsePathStyle = true
		},
	}
	if cfg.Endpoint != "" {
		scheme := "https"
		if !cfg.UseSSL {
			scheme = "http"
		}
		// Normalise: strip any existing scheme from Endpoint so we control it.
		ep := cfg.Endpoint
		ep = strings.TrimPrefix(ep, "http://")
		ep = strings.TrimPrefix(ep, "https://")
		endpointURL := scheme + "://" + ep
		opts = append(opts, func(o *s3.Options) {
			o.BaseEndpoint = aws.String(endpointURL)
		})
	}

	client := s3.NewFromConfig(awsCfg, opts...)
	return &S3Backend{client: client, cfg: cfg}, nil
}

// Save uploads manifest.json then replay.bin to S3. The manifest is mutated
// (ReplaySHA256Hex and CreatedAt set) before the upload.
func (b *S3Backend) Save(ctx context.Context, m *Manifest, replay io.Reader) error {
	// Read all replay bytes into memory so we can (a) compute the hash and (b)
	// provide a Content-Length for the PutObject call. For typical replay files
	// (~1-10 MB) this is fine; if we ever need streaming PutObject we'd use
	// TransferManager instead.
	replayBytes, err := io.ReadAll(replay)
	if err != nil {
		return fmt.Errorf("replay s3: read replay bytes: %w", err)
	}

	// Compute SHA-256 and fill manifest fields.
	h := sha256.New()
	h.Write(replayBytes)
	m.ReplaySHA256Hex = hex.EncodeToString(h.Sum(nil))
	if m.CreatedAt.IsZero() {
		m.CreatedAt = time.Now().UTC()
	}

	// Check whether the round already exists (manifest.json present) before
	// uploading to honour the write-once contract.
	manifestKey := b.manifestKey(m.RoundID)
	_, headErr := b.client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(b.cfg.Bucket),
		Key:    aws.String(manifestKey),
	})
	if headErr == nil {
		// Object exists.
		return fmt.Errorf("%w: round_id=%d key=%s", ErrRoundExists, m.RoundID, manifestKey)
	}
	if !isNotFound(headErr) {
		return fmt.Errorf("replay s3: head manifest: %w", headErr)
	}

	// Marshal manifest JSON.
	manifestBytes, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("replay s3: marshal manifest: %w", err)
	}

	roundIDStr := fmt.Sprintf("%d", m.RoundID)
	contentTypeJSON := "application/json"
	contentTypeBin := "application/octet-stream"

	// Upload replay.bin first so a crash between the two uploads leaves the
	// round in an incomplete state (no manifest → List/Load skip it).
	replayKey := b.replayKey(m.RoundID)
	replaySize := int64(len(replayBytes))
	if _, err := b.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:        aws.String(b.cfg.Bucket),
		Key:           aws.String(replayKey),
		Body:          bytes.NewReader(replayBytes),
		ContentLength: aws.Int64(replaySize),
		ContentType:   aws.String(contentTypeBin),
		Metadata: map[string]string{
			"round-id": roundIDStr,
			"sha256":   m.ReplaySHA256Hex,
		},
	}); err != nil {
		return fmt.Errorf("replay s3: put replay.bin: %w", err)
	}

	// Upload manifest.json — its presence is the "committed" signal.
	manifestSize := int64(len(manifestBytes))
	if _, err := b.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:        aws.String(b.cfg.Bucket),
		Key:           aws.String(manifestKey),
		Body:          bytes.NewReader(manifestBytes),
		ContentLength: aws.Int64(manifestSize),
		ContentType:   aws.String(contentTypeJSON),
		Metadata: map[string]string{
			"round-id": roundIDStr,
			"sha256":   m.ReplaySHA256Hex,
		},
	}); err != nil {
		return fmt.Errorf("replay s3: put manifest.json: %w", err)
	}

	return nil
}

// Load downloads manifest.json and returns it together with a streaming
// GetObject body for replay.bin. The caller must close the returned
// io.ReadCloser.
func (b *S3Backend) Load(ctx context.Context, roundID uint64) (*Manifest, io.ReadCloser, error) {
	// Fetch manifest.
	manifestObj, err := b.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(b.cfg.Bucket),
		Key:    aws.String(b.manifestKey(roundID)),
	})
	if err != nil {
		if isNotFound(err) {
			return nil, nil, fmt.Errorf("%w: round_id=%d", ErrRoundMissing, roundID)
		}
		return nil, nil, fmt.Errorf("replay s3: get manifest: %w", err)
	}
	defer manifestObj.Body.Close()

	manifestBytes, err := io.ReadAll(manifestObj.Body)
	if err != nil {
		return nil, nil, fmt.Errorf("replay s3: read manifest body: %w", err)
	}
	var m Manifest
	if err := json.Unmarshal(manifestBytes, &m); err != nil {
		return nil, nil, fmt.Errorf("replay s3: parse manifest: %w", err)
	}

	// Open replay.bin stream.
	replayObj, err := b.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(b.cfg.Bucket),
		Key:    aws.String(b.replayKey(roundID)),
	})
	if err != nil {
		if isNotFound(err) {
			return nil, nil, fmt.Errorf("%w: round_id=%d (replay.bin missing)", ErrRoundMissing, roundID)
		}
		return nil, nil, fmt.Errorf("replay s3: get replay.bin: %w", err)
	}

	return &m, replayObj.Body, nil
}

// List pages through bucket objects under the configured prefix and returns
// all committed manifests (those that have a manifest.json object) in
// ascending round_id order.
func (b *S3Backend) List(ctx context.Context, opts ListOpts) ([]*Manifest, error) {
	prefix := b.cfg.PathPrefix
	// We use a delimiter "/" to get one "virtual directory" per round_id.
	// Each common prefix looks like "<pathPrefix><round_id>/".
	paginator := s3.NewListObjectsV2Paginator(b.client, &s3.ListObjectsV2Input{
		Bucket:    aws.String(b.cfg.Bucket),
		Prefix:    aws.String(prefix),
		Delimiter: aws.String("/"),
	})

	var manifests []*Manifest
	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("replay s3: list objects: %w", err)
		}
		for _, cp := range page.CommonPrefixes {
			if cp.Prefix == nil {
				continue
			}
			// cp.Prefix is like "<pathPrefix><round_id>/"
			roundStr := strings.TrimSuffix(strings.TrimPrefix(*cp.Prefix, prefix), "/")
			var roundID uint64
			if _, err := fmt.Sscanf(roundStr, "%d", &roundID); err != nil {
				continue // not a numeric round directory
			}
			if opts.After > 0 && roundID <= opts.After {
				continue
			}
			// Fetch the manifest for this round.
			obj, err := b.client.GetObject(ctx, &s3.GetObjectInput{
				Bucket: aws.String(b.cfg.Bucket),
				Key:    aws.String(b.manifestKey(roundID)),
			})
			if err != nil {
				if isNotFound(err) {
					// Orphaned replay.bin (upload interrupted) — skip.
					continue
				}
				return nil, fmt.Errorf("replay s3: get manifest for round %d: %w", roundID, err)
			}
			raw, err := io.ReadAll(obj.Body)
			obj.Body.Close()
			if err != nil {
				return nil, fmt.Errorf("replay s3: read manifest for round %d: %w", roundID, err)
			}
			var m Manifest
			if err := json.Unmarshal(raw, &m); err != nil {
				continue // corrupt manifest — skip rather than fail the whole list
			}
			manifests = append(manifests, &m)
			if opts.Limit > 0 && len(manifests) >= opts.Limit {
				return manifests, nil
			}
		}
	}

	// S3 listing order is lexicographic on keys. Since round IDs are
	// decimal-encoded, lexicographic order != numeric order for IDs of
	// different digit lengths. Sort explicitly.
	sortManifests(manifests)
	return manifests, nil
}

// Delete removes both objects for the round. Returns ErrRoundMissing if
// manifest.json is absent.
func (b *S3Backend) Delete(ctx context.Context, roundID uint64) error {
	// Confirm the round exists.
	_, err := b.client.HeadObject(ctx, &s3.HeadObjectInput{
		Bucket: aws.String(b.cfg.Bucket),
		Key:    aws.String(b.manifestKey(roundID)),
	})
	if err != nil {
		if isNotFound(err) {
			return fmt.Errorf("%w: round_id=%d", ErrRoundMissing, roundID)
		}
		return fmt.Errorf("replay s3: head manifest for delete: %w", err)
	}

	objs := []types.ObjectIdentifier{
		{Key: aws.String(b.manifestKey(roundID))},
		{Key: aws.String(b.replayKey(roundID))},
	}
	if _, err := b.client.DeleteObjects(ctx, &s3.DeleteObjectsInput{
		Bucket: aws.String(b.cfg.Bucket),
		Delete: &types.Delete{Objects: objs},
	}); err != nil {
		return fmt.Errorf("replay s3: delete objects for round %d: %w", roundID, err)
	}
	return nil
}

func (b *S3Backend) manifestKey(roundID uint64) string {
	return fmt.Sprintf("%s%d/manifest.json", b.cfg.PathPrefix, roundID)
}

func (b *S3Backend) replayKey(roundID uint64) string {
	return fmt.Sprintf("%s%d/replay.bin", b.cfg.PathPrefix, roundID)
}

// isNotFound reports whether err is an S3 404 / NoSuchKey error.
func isNotFound(err error) bool {
	if err == nil {
		return false
	}
	var nsk *types.NoSuchKey
	if errors.As(err, &nsk) {
		return true
	}
	// HeadObject returns a generic 404 wrapped in smithy *ResponseError;
	// check the string as a fallback for SDK version variance.
	return strings.Contains(err.Error(), "404") ||
		strings.Contains(err.Error(), "NoSuchKey") ||
		strings.Contains(err.Error(), "NotFound")
}

// sortManifests sorts a slice of manifests by RoundID ascending in-place.
func sortManifests(ms []*Manifest) {
	for i := 1; i < len(ms); i++ {
		for j := i; j > 0 && ms[j].RoundID < ms[j-1].RoundID; j-- {
			ms[j], ms[j-1] = ms[j-1], ms[j]
		}
	}
}
