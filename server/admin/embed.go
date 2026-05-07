package admin

import (
	"embed"
	"io/fs"
)

//go:embed templates static
var embeddedTemplates embed.FS

// embeddedFS returns the embedded file system. Exposed for tests that want to
// construct a Handler without providing their own TemplateFS.
func embeddedFS() fs.FS {
	return embeddedTemplates
}
