class_name HudI18n
extends Object

# Lightweight i18n table for the HUD.
#
# Replaces hardcoded English strings with a t(key) lookup so the HUD can
# be re-localised without rewriting every label-text assignment. Default
# language is English; tier-1 European casino markets (IT, DE, ES, PT)
# are scaffolded with empty maps that fall back to English when a key
# isn't translated yet — no crash on missing translations.
#
# Why a static singleton-like Object instead of Godot's TranslationServer:
#   - The HUD strings are ~30 keys; full TranslationServer setup with
#     .po/.mo files is overkill at this stage.
#   - Operator-side localisation overrides (passed via theme runtime)
#     can re-call set_lang() on round start without touching the
#     project's TranslationServer state.
# Migration to TranslationServer is a one-line change inside t() if/when
# the catalogue grows past the manageable point.
#
# Usage:
#   HudI18n.set_lang("it")
#   var s := HudI18n.t("hud.bet.cta")     # "PIAZZA SCOMMESSA"
#
# Conventions:
#   - keys are dotted lowercase namespaces ("hud.bet.cta", "hud.timer.caption")
#   - values are uppercase only when the UI shows them uppercase
#     (the Label doesn't auto-uppercase; that's the translator's call)

const LANG_EN := "en"
const LANG_IT := "it"
const LANG_ES := "es"
const LANG_DE := "de"
const LANG_PT := "pt"

# Master English table — every key exists here. Other languages fall back
# to this map when their key is missing.
const _EN := {
	# Top bar
	"hud.brand.default":            "MARBLES",
	"hud.balance.caption":          "BALANCE",
	"hud.balance.currency":         "USD",

	# Phase pill
	"hud.phase.waiting":            "WAITING",
	"hud.phase.racing":             "RACING",
	"hud.phase.finished":           "FINISHED",

	# Timing tower
	"hud.standings.header":         "STANDINGS",
	"hud.standings.count_suffix":   "MARBLES",

	# Timer
	"hud.timer.caption":            "RACE TIME",
	"hud.timer.bets_locked":        "BETS LOCKED",

	# Bet panel
	"hud.bet.header":               "PLACE YOUR BET",
	"hud.bet.countdown.starts_in":  "RACE STARTS IN %.1fs",
	"hud.bet.countdown.locked":     "BETS LOCKED",
	"hud.bet.pick_marble":          "PICK A MARBLE",
	"hud.bet.stake_caption":        "STAKE",
	"hud.bet.potential_win":        "POTENTIAL WIN",
	"hud.bet.potential_win_value":  "POTENTIAL WIN  +%s",
	"hud.bet.cta":                  "PLACE BET",
	"hud.bet.your_bets":            "YOUR BETS",
	"hud.bet.insufficient":         "Insufficient balance",
	"hud.bet.placed":               "Bet placed: Marble %02d — %s",

	# Winner modal
	"hud.winner.caption":           "WINNER",
	"hud.winner.race_complete":     "Race complete",
	"hud.winner.next_round_in":     "NEXT ROUND IN %.1fs",
	"hud.winner.starting":          "STARTING NEXT ROUND…",

	# Toasts (default to English; operator can override)
	"hud.toast.bet_placed":         "Bet placed",
	"hud.toast.bet_failed":         "Bet failed",

	# Track display names (M11 themes)
	"hud.track.forest_run":         "FOREST RUN",
	"hud.track.volcano_run":        "VOLCANO RUN",
	"hud.track.ice_run":            "ICE RUN",
	"hud.track.cavern_run":         "CAVERN RUN",
	"hud.track.sky_run":            "SKY RUN",
	"hud.track.stadium_run":        "STADIUM RUN",
	"hud.track.ramp":               "RAMP",
}

# Italian — partial; missing keys fall back to English.
const _IT := {
	"hud.balance.caption":          "SALDO",
	"hud.phase.waiting":            "ATTESA",
	"hud.phase.racing":             "IN GARA",
	"hud.phase.finished":           "TERMINATA",
	"hud.standings.header":         "CLASSIFICA",
	"hud.standings.count_suffix":   "BIGLIE",
	"hud.timer.caption":            "TEMPO GARA",
	"hud.timer.bets_locked":        "PUNTATE CHIUSE",
	"hud.bet.header":               "PIAZZA LA TUA PUNTATA",
	"hud.bet.countdown.starts_in":  "GARA INIZIA TRA %.1fs",
	"hud.bet.countdown.locked":     "PUNTATE CHIUSE",
	"hud.bet.pick_marble":          "SCEGLI UNA BIGLIA",
	"hud.bet.stake_caption":        "PUNTATA",
	"hud.bet.potential_win":        "VINCITA POTENZIALE",
	"hud.bet.potential_win_value":  "VINCITA POTENZIALE  +%s",
	"hud.bet.cta":                  "PIAZZA SCOMMESSA",
	"hud.bet.your_bets":            "LE TUE PUNTATE",
	"hud.bet.insufficient":         "Saldo insufficiente",
	"hud.bet.placed":               "Puntata piazzata: Biglia %02d — %s",
	"hud.winner.caption":           "VINCITORE",
	"hud.winner.race_complete":     "Gara terminata",
	"hud.winner.next_round_in":     "PROSSIMO ROUND IN %.1fs",
	"hud.winner.starting":          "INIZIO PROSSIMO ROUND…",
	"hud.track.forest_run":         "PISTA FORESTA",
	"hud.track.volcano_run":        "PISTA VULCANO",
	"hud.track.ice_run":            "PISTA GHIACCIO",
	"hud.track.cavern_run":         "PISTA CAVERNA",
	"hud.track.sky_run":            "PISTA CIELO",
	"hud.track.stadium_run":        "PISTA STADIO",
}

# Spanish — partial.
const _ES := {
	"hud.balance.caption":          "SALDO",
	"hud.phase.waiting":            "ESPERANDO",
	"hud.phase.racing":             "EN CARRERA",
	"hud.phase.finished":           "FINALIZADA",
	"hud.standings.header":         "CLASIFICACIÓN",
	"hud.standings.count_suffix":   "CANICAS",
	"hud.timer.caption":            "TIEMPO",
	"hud.timer.bets_locked":        "APUESTAS CERRADAS",
	"hud.bet.header":               "REALIZA TU APUESTA",
	"hud.bet.countdown.starts_in":  "CARRERA EMPIEZA EN %.1fs",
	"hud.bet.countdown.locked":     "APUESTAS CERRADAS",
	"hud.bet.pick_marble":          "ELIGE UNA CANICA",
	"hud.bet.stake_caption":        "APUESTA",
	"hud.bet.potential_win":        "GANANCIA POSIBLE",
	"hud.bet.potential_win_value":  "GANANCIA POSIBLE  +%s",
	"hud.bet.cta":                  "APOSTAR",
	"hud.bet.your_bets":            "TUS APUESTAS",
	"hud.bet.insufficient":         "Saldo insuficiente",
	"hud.winner.caption":           "GANADOR",
	"hud.winner.next_round_in":     "PRÓXIMA RONDA EN %.1fs",
}

# German — partial.
const _DE := {
	"hud.balance.caption":          "GUTHABEN",
	"hud.phase.waiting":            "WARTEN",
	"hud.phase.racing":             "RENNEN",
	"hud.phase.finished":           "BEENDET",
	"hud.standings.header":         "PLATZIERUNG",
	"hud.standings.count_suffix":   "KUGELN",
	"hud.timer.caption":            "RENNZEIT",
	"hud.timer.bets_locked":        "WETTEN GESPERRT",
	"hud.bet.header":               "WETTE PLATZIEREN",
	"hud.bet.countdown.starts_in":  "RENNEN STARTET IN %.1fs",
	"hud.bet.countdown.locked":     "WETTEN GESPERRT",
	"hud.bet.pick_marble":          "KUGEL WÄHLEN",
	"hud.bet.stake_caption":        "EINSATZ",
	"hud.bet.potential_win":        "MÖGLICHER GEWINN",
	"hud.bet.potential_win_value":  "MÖGLICHER GEWINN  +%s",
	"hud.bet.cta":                  "WETTE PLATZIEREN",
	"hud.bet.your_bets":            "DEINE WETTEN",
	"hud.winner.caption":           "GEWINNER",
	"hud.winner.next_round_in":     "NÄCHSTE RUNDE IN %.1fs",
}

# Portuguese — partial.
const _PT := {
	"hud.balance.caption":          "SALDO",
	"hud.phase.waiting":            "AGUARDANDO",
	"hud.phase.racing":             "EM CORRIDA",
	"hud.phase.finished":           "TERMINADA",
	"hud.standings.header":         "CLASSIFICAÇÃO",
	"hud.standings.count_suffix":   "BOLINHAS",
	"hud.timer.caption":            "TEMPO",
	"hud.bet.header":               "FAÇA SUA APOSTA",
	"hud.bet.cta":                  "APOSTAR",
	"hud.winner.caption":           "VENCEDOR",
}

const _BY_LANG := {
	LANG_EN: _EN,
	LANG_IT: _IT,
	LANG_ES: _ES,
	LANG_DE: _DE,
	LANG_PT: _PT,
}

# Active language. Defaults to en; settable via set_lang() at any time.
# Module-level static state — intentional: i18n is process-global.
static var _current_lang: String = LANG_EN

static func set_lang(lang: String) -> void:
	if _BY_LANG.has(lang):
		_current_lang = lang
	else:
		push_warning("HudI18n: unknown lang '%s', staying on '%s'" % [lang, _current_lang])

static func current_lang() -> String:
	return _current_lang

# Look up a translation. Falls back to the English value, then to the key
# itself if the key doesn't exist anywhere. Never crashes on missing keys.
static func t(key: String) -> String:
	var lang_table: Dictionary = _BY_LANG.get(_current_lang, _EN)
	if lang_table.has(key):
		return String(lang_table[key])
	if _EN.has(key):
		return String(_EN[key])
	return key
