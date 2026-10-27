<!-- Kopie der Projektdatei konzepte/review-lektionen/LEKTIONEN.md für den Upstream-Review-Job; bereinigt, Quelle sind die Projektdateien. -->
# Review-Lektionen (Prüfliste aus echten Review-Befunden)

Freigegeben am 07.10.2026. Grundlage: 741 Befunde in 125 PRs (Upstream we-promise/sure 101 PRs,
Fork gfr-free/sure 81 PRs); Quellen CodeRabbit, Codex, Claude-Review, Maintainer.
Rohliste (741 Zeilen) liegt außerhalb dieses Repos.

## Wie diese Datei benutzt wird
- **Seit 16.10.2026:** Der vollständige Review-Ablauf steht in REVIEW-PROMPT.md (gleicher Ordner); diese Datei
  ist dessen Prüfliste (Schritt 3 und 6). Neue Lektionen weiter hier eintragen.
- **Review (Pflicht, vor jedem PR):** /code-review und /security-review bekommen diese Datei als
  Zusatzauftrag. Jede Lektion, die zum Diff passt, wird im Thread mit einem Satz beantwortet
  (z. B. „L2: Wege Web/API/Import geprüft, je ein Test“). Nicht passende weglassen.
- **Beim Bauen (nur bei Rechte-, Sperr- oder Import-Logik):** vorher die Wege-Tabelle aus L2 anlegen;
  sie steht später in der Fork-PR-Beschreibung.
- **Rückkopplung (automatisch, Owner 07.10.):** Wer einen Review-Befund behebt (PR-Thread, Fork-PR-Job,
  05:27-Job), ordnet ihn einer Lektion zu. Neue Fehlerart → neue Lektion anhängen. Bekannte Art, die trotz
  Prüffrage durchgerutscht ist → Beispiel ergänzen und die Prüffrage schärfen. Ohne Rückfrage, Eintrag mit Datum.

## Lektionen (Häufigkeit = Befunde in der Auswertung)

**L1 Datenrandfälle bei jedem neuen Feld (211).**
Normalisierung auf beiden Seiten (Groß/Klein, alle Leerzeichenarten, UUID, Locale)? nil, leer und
„bewusst geleert“ unterschieden? Re-Import/Update mit fehlendem oder ungültigem Wert überschreibt nichts
(nur vorhandene Keys anwenden, Ungültiges ablehnen)? Export/Import-Roundtrip und Readback-Zählung
enthalten das Feld? Dedup behält die reichere Zeile? Geld als Decimal, Vorzeichen, Währung (Konto vs. Familie)? Vorbelegte Geldfelder mit JPY (0 Nachkommastellen): speichert unverändertes Absenden denselben Wert (upstream 4184)?
Beispiele: 3513, 3516, 3008, 3098; Fork 59, 60, 66, 68.

**L2 Alle Wege mit derselben Wirkung (55 + 40).**
Mit grep alle Einstiege aufzählen: Web-Actions (auch revert, cancel, destroy, apply_template, bulk),
Schwester- und verschachtelte Controller, API v1, Mobile/Doorkeeper, OIDC/SSO, /sidekiq, Assistant-Functions,
Importer/Exporter aller Typen, Rule-Import, Preflight/Vorschau, Jobs, Insights/Generatoren, Backfill-Tasks,
ActiveStorage-Downloads, Turbo/JSON-Formate, Turbo-Broadcasts auf Familien-Streams (L24). Je Weg: geprüft ja/nein, ein Test.
Rechte: family, accessible_by/writable_by (Kontofreigaben, read-only), Rolle (Gast), Feature-Flag (ai_enabled).
Nebenwirkungen zählen mit: legt ein erlaubter Vorgang Kategorien, Tags, Konten oder Händler an, gilt dieselbe Prüfung.
Familienweite Berechnungen (Insights, Assistant, Berichte) mit viewer scopen, sonst sehen Mitglieder fremde Konten.
Globale geteilte Objekte (ProviderMerchant, Security) nie durch eine Familien-Aktion ändern.
Gleiche Fehlermeldung für „gibt es nicht“ und „kein Recht“.
Beispiele: 4005, 4000, 3998, 2890, 3242, 3263, 3034, 3397; Fork 15, 23, 35, 38, 56, 64, 66.

**L3 Security bei sensiblen Daten (72).**
Neue sensible Spalte: encrypts + Backfill bestehender Klartextwerte + Redaction + Privacy-Mode.
Keine PII/IBAN in DebugLogEntry, Logs oder Fehlermeldungen; Redaction-Muster um neue Keys erweitern.
Audit: bei Impersonation true_user als Akteur, Audit-Schreiben atomar mit der Aktion. Zustandsänderung nie per GET. Kein innerHTML.
Externe URLs: nur https für Tokens, SSRF-Guard mit allen nicht-öffentlichen Bereichen.
Beispiele: 3513, 3515, 3833, 3189, 3246, 3008, 3032; Fork 56.

**L4 Race und Unique-Kollision (52).**
find-or-create und Check-then-write: Lock, Recheck oder atomares Update. RecordNotUnique abfangen,
und zwar in einem Savepoint (requires_new), sonst bricht die PG-Transaktion ab; nie 500.
Seiteneffekt und Audit atomar. Client-Reorder: Saves serialisieren, Fehler zurückrollen.
Beispiele: 3340, 3824, 3034, 3264; Fork 33, 42, 54, 71.

**L5 Migrationen (42).**
Aktuelle Migrationsversion (nicht 7.2). Unique-Index: vorher Duplikate bereinigen oder Preflight.
CONCURRENTLY mit if_not_exists und concurrent Rollback. CHECK-Constraint mit NOT VALID + validate.
Kein Datenverlust (Status-Mapping vor Spalten-Drop), Backfill deckt alle Subtypen ab.
Nichts Unbezogenes mitschicken (keine fremden Migrationen aus alten Branches).
Beispiele: 3340, 3242, 3342, 3790, 3827, 4017; Fork 15, 19, 20, 74.

**L6 UI-Zustand (55).**
Fehler-Re-Render (Formularwerte bleiben), turbo_stream-Update, bfcache/Prefetch, Tastatur, Touch
(touchcancel), Modifier-Klicks, ARIA-Namen einzeln durchspielen.
Beispiele: 3103, 3361, 3378, 3132, 3754; Fork 21, 46.

**L7 Tests, die wirklich prüfen (47).**
Neuen Test einmal ohne den Fix laufen lassen: er muss rot sein. Keine Abhängigkeit von Uhrzeit,
Zeitzone oder Mitternacht (travel_to). Settings/ENV zurücksetzen. Starke Assertions, Query-Count-Test bei N+1-Fixes.
Beispiele: 3103, 3242, 3020, 2821, 3830; Fork 35, 48.

**L8 Fehlerbehandlung (45).**
Ungültige Eingaben (fehlender Param, UUID, Enum, Ziffern mit führender Null) → Validierungsfehler statt 500.
DebugLogEntry.capture statt nur Rails.logger. Keine rohen DB-Fehler beim User. rescue weder zu eng noch zu breit.
Enqueue nach Commit, Fehler dort abfangen. Retries nur für vorübergehende Fehler, dauerhafte sauber beenden.
Beispiele: 3020, 3361, 3811, 2828, 3340; Fork 15, 19, 56, 72.

**L9 Cache-Keys (in L1 gezählt).**
Key enthält alles, was das Ergebnis ändert: Löschungen, Status, FX-Kurse, Namen, viewer;
updated_at mit Sekundenbruchteilen. Beispiele: 3058; Fork 31, 46, 47, 67, 81.

**L10 Eine Größe, ein Rechenweg.**
Wird derselbe Wert an zwei Stellen berechnet (Ansicht vs. Modell, Budget vs. Steuer), gleicher Scope,
gleiche Währung, gleiche Methode (z. B. next_due_date statt Cache-Hinweis). Fork 15, 53, 64, 66.

**L11 i18n (40).** Neue Keys in allen vorhandenen Locales (mindestens en + de), keine hartcodierten Strings in
Views, JS oder gespeicherten Notizen, keine Vergleiche auf übersetzte Texte, YAML-Fallen (on/off quoten,
doppelte Keys, doppelte Labels). Beispiele: 2890, 3264, 3754, 3034, 2945; Fork 15, 22.

**L12 Design-System (28, meist Maintainer).** Vor jedem handgebauten Element app/components/DS/ prüfen
(Disclosure, Tooltip, Pill, Button, Alert, RadioCard). Nur Tokens, keine Palette/Hex. Beispiele: 3008, 3020, 3034, 3811, 4017.

**L13 Scope und PR-Hygiene (19).** Branch frisch von upstream main, keine fremden Änderungen, PR-Text
und UI-Hinweistexte stimmen mit dem Code überein (kein Hinweis auf eine Funktion, die nicht verdrahtet ist; IBAN-Serie 5×), keine falschen Angaben zum Stacking. Beispiele: 3518, 3221, 3511, 3719.

**L14 Performance (15).** Kein Query pro Zeile (pluck/find_by in Schleifen), Memoisierung,
Index für neue Lookups und DISTINCT. Beispiele: 3020, 3397, 3573, 4018.

**L15 API-Doku und Vertrag (11).** rswag mit allen Statuscodes (401/403), openapi neu erzeugt, Beschreibungen
stimmen, neue Enum-Werte oder null-IDs in v1 sind ein Breaking Change. Beispiele: 2890, 3008; Fork 64, 65.

## Lektionen aus fremden Upstream-PRs (07.10.2026)
Grundlage: 1.758 PRs anderer Autoren, 3.358 Befunde (Maintainer seit 07.04., Bots seit 07.07.).
Häufigste Lektionen dort: L1 (465), L13 (299), L7 (276), L6 (232), L8 (225), L11 (212). Rohdaten liegen außerhalb dieses Repos.

**L16 Provider-Sync-Semantik (78 + viele unter L1/L8).**
Was passiert bei Teilantwort, fehlender Seite 2, Retry nach Timeout (nicht-idempotente POSTs), leerer oder
wechselnder externer ID, pending→posted, Rate-Limit, Token-Rotation? Wird ein Teilfehler als Erfolg gemeldet?
Kein HTTP-Call innerhalb einer DB-Transaktion oder eines with_lock. Formatwechsel von Secrets darf Bestandsnutzer
nicht still brechen. Neue Provider über Provider-Generator und Provider::HttpTransport. Beispiele: 3669, 2747, 3094, 1425, 1888.

**L17 Duplikat und Reproduktion auf main (57 + 42 Schließungen).**
Vor Arbeitsbeginn: offener oder neuerer PR zum selben Thema? Ist der Fehler auf aktuellem main noch reproduzierbar
und der Fall überhaupt erreichbar? Beispiele: 1478, 1931, 1968, 2710, 2711.

**L18 Konfiguration und Self-Hoster (47).**
Neue ENV-Variable oder geänderter Default: .env.example, Hosting-Doku, Upgrade-Hinweis. Möglichst wenige neue
ENV-Variablen. Externe Drittanbieter-Calls nur per Opt-in. Fallback entfernen bricht Bestandsinstallationen.
Beispiele: 894, 1832, 1816.

**L19 Produktpassung vor großen Features (23 + ca. 13 Schließungen).**
Neues Konzept, neuer Provider, neues Setting: vorher Zustimmung der Maintainer (Issue/Discussion). Generisch statt
anbieter- oder händlerspezifisch. Kann ein vorhandenes Konzept es abdecken (Splits, Goals, Regeln, Preview-Flag,
OpenAI-kompatible URL, External AI/MCP)? Beispiele: 1672, 1968, 1485, 858, 3889, 3960.

**L20 PR-Erwartungen der Maintainer (Stichwortzählung).**
Beschreibung und Testplan aktuell zum Diff (57 PRs), Vorher/Nachher-Screenshots mit Demo-Daten (21), Branch
aktuell und konfliktfrei (103), CI grün (65), jeder Bot- und Review-Thread beantwortet oder aufgelöst, bevor
Review angefordert wird (29), höchstens wenige Commits bzw. squashen (18), große PRs aufteilen (ca. 66 „changes requested“).

**L21 Wiederverwenden statt duplizieren, dünne Controller (ca. 44).**
Gibt es schon Helper, Generator, Transport, Api::V1::BaseController-Helfer (UUID, Pagination), DS-Baustein?
Logik ins Model oder Query-Objekt, kein Roh-SQL im Controller. Kein neues Pre-1.0-Gem, lieber vendoren.
Beispiele: 1720, 1722, 1635, 3386, 3473, 2619.

**L22 Ursache statt Symptom (Einzelfälle, hohes Gewicht).**
Behebe ich die Ursache oder verdecke ich sie mit einem defensiven Guard? Passt das Modell zur Domäne?
Aggregator-Bugs beim Anbieter melden statt app-seitig umgehen. Beispiele: 2957, 2982.

**L24 Broadcasts und andere Wege ohne Betrachter (neu 07.10.).**
Turbo-Broadcasts (`broadcast_*_to family`, `Turbo::StreamsChannel.broadcast_*`) laufen an Controller-Rechten
vorbei: Jede angemeldete Person der Familie abonniert den Familien-Stream (Layout `_htmldoc.html.erb`),
auch Gäste und Mitglieder ohne Kontofreigabe. Das HTML landet im Browser, auch wenn das Ziel-Element
auf der Seite fehlt. Beim Rendern ist `Current.user` nil, also filtert kein Partial nach Rechten.
Prüffragen: Was steht im gesendeten Partial (Geheimnisse, Formularwerte, Admin-Bereiche, Namen und Salden
nicht geteilter Konten)? Wer abonniert den Stream, und darf jede dieser Personen alles darin sehen?
Admin-only Partials (Einstellungen) nie auf den Familien-Stream; Konto-Inhalte nur auf Konto-Streams oder
gefiltert. Gespeicherte Geheimnisse nie zurück ins Formular rendern (`value: nil`, Hinweis „gespeichert“).
Test: `capture_broadcasts(Turbo::StreamsChannel.send(:stream_name_from, family))` und prüfen, dass weder
Geheimnis noch fremder Kontoname enthalten ist.
Beispiele: Sync-Ereignisse, die ein Einstellungs-Panel oder Kontokarten an den Familien-Stream senden;
Provider-Panels, die gespeicherte Zugangsdaten ins Admin-Formular rendern (verwandt mit upstream issue 3630).

**L25 Rechte-Filter als Local dürfen nicht „fail-open“ sein (neu 08.10., Review upstream PR 4048).**
Bekommt ein Partial oder eine Komponente einen Rechte-Filter als Local (z. B. `visible_accounts:`),
darf der Default nicht „alles“ sein (`visible_accounts: item.accounts`). Sonst öffnet jeder Render ohne
diesen Local (Broadcast, Controller-Antwort nach Setup/Link, neue Seite) die Lücke wieder, ohne dass ein
Test rot wird. Prüffragen: Was zeigt das Partial, wenn der Local fehlt? Gibt es einen Test, der alle
Render-Stellen auflistet (grep nach `partial: "x/y"` und `render x`) und für jede den Filter verlangt?
Besser: Default leer bzw. „nur Zählwerte“, oder Pflicht-Local ohne Default.
Beispiel: upstream PR 4048 (Provider-Karten), aktuell nur durch admin-only Render-Stellen und den
Broadcast-Rückbau in upstream PR 4046 abgesichert.

**L26 Explizite Reihenfolge (neu 13.10., Bugfix-Rückblick).**
Hat jede Query oder Association, deren Reihenfolge sichtbar ist oder für eine Zuordnung zählt (Bulk-Index,
Formularzeilen, Auswahllisten), ein ORDER BY mit eindeutigem Tiebreaker (z. B. `name, id`)? Ohne ORDER BY
liefert Postgres beliebig, was erst in Produktion auffällt. Beispiele: upstream 2402, 2429.

**L27 Heuristiken ohne Mensch: Detektoren und Auto-Matcher (neu 13.10.).**
Welche Kontotypen (Investment, Krypto, Kredit, manuell, NULL) und Eintragsarten (Trade, Valuation, Dividende)
speisen den Detektor (wiederkehrend, Transfer-Matching, Händlererkennung)? Ist das Falsch-Positiv-Verhalten
samt Bestandsdaten bewusst entschieden, und gibt es je ausgeschlossenem Typ einen Test? Toleranzen (Betrag,
Währung, Datum) eng und begründet. Beispiele: upstream 3565 (Dividenden als Rechnungen), 3309 (10 % Toleranz).

**L28 Bedeutung aus Vorzeichen oder Menge (neu 13.10.).**
Leitet eine Abfrage Bedeutung allein aus Vorzeichen, Menge oder Kontotyp ab (qty < 0 = Verkauf, negativ auf
Kreditkarte = Zahlung)? Dann bei jedem neuen Typ oder Label prüfen, ob er fälschlich mitgezählt wird
(Depotübertrag, Erstattung, Gutschrift, Gebühr). Besser explizites kind/Label. Beispiele: upstream 3192, 3062.

**L29 Verwaiste Verweise beim Löschen (neu 13.10.).**
Welche Datensätze verweisen auf das zu löschende Objekt (Transfer, RejectedTransfer, Statement-Links,
Split-Kinder)? Werden sie per dependent/before_destroy mitentfernt, oder vertragen Leser und Importer das
Fehlen? Test: Objekt löschen, danach Liste, Import und Sync laufen lassen. Beispiele: upstream 1795;
Fork 80 (Barren-Spezifikation mit fremden Trades).

**L30 Handgepflegte Listen und Allowlists (neu 13.10.).**
Muss ein neuer Provider, Typ oder ein neues Institut in eine handgepflegte Liste (Nightly-Sync, Cleanup,
Export, Institut-Allowlist für Sonderformate)? Lieber per Reflection ableiten und mit einem Test absichern,
der alle Provider gegen die Liste prüft; bei Format-Allowlists zusätzlich eine Plausibilitätsprüfung
(z. B. cost_basis gegen Kurs × Menge), die unbekannte Fälle meldet. Beispiele: upstream 2334, 2986, 3619.

**L31 Zeitbezug: Gültig-ab-Werte und Reihenfolge von Ereignissen (neu 13.10.).**
Werte mit Gültigkeitszeitraum (Steuersätze je Jahr, Aktionspreise, Kurse): Bearbeiten legt einen neuen
Zeitraum an statt den geerbten zu ändern, Auswahl nach Buchungs-/Nutzungsdatum, Test am Stichtag (31.12./01.01.).
Abgeleitete Zahlen: gleiches Ergebnis, egal ob das manuelle Ereignis vor oder nach dem Sync der Quelle kommt
(Test für beide Reihenfolgen). Beispiele: upstream 3219; Fork 66 (Steuerprofil), Fork 79 (LLM-Preise ab 2027).

**L32 Hinweis auch in den Insights? (neu 13.10., Owner-Vorgabe).**
Zeigt eine Änderung einen neuen Warn- oder Problemhinweis an einer Stelle, die man erst öffnen muss (Konto-Reiter,
Detailseite, Einstellungen), prüfen: Gehört derselbe Zustand als Insight-Generator in den Insights-Feed? Ja, wenn
der Zustand die Finanzen betrifft und der Nutzer handeln muss (Datenfehler, Schwelle gerissen, Frist). Dann:
Generator mit `produces`, Eintrag in `Insight::TYPES` und `GeneratorRegistry`, Icon/Aktion/Kennzahl im
`InsightsHelper`, Texte (types, actions, titles, templates) in allen Sprachen, nur Konten aus
`accessible_by_all_active_members`, Test für Erzeugen, Nicht-Erzeugen und Rechte. Nein (kurz begründen), wenn der
Hinweis nur Bedienung betrifft. Im PR und im Thread mit einem Satz beantworten. Beispiel: Fork 105 (negative Bestände).

**L33 Eingabeprüfung: falsch, leer, negativ, Komma (neu 17.10., Owner-Vorgabe).**
Für jedes neue oder geänderte Eingabefeld auf jedem Weg (Formular, API v1, Import, Regel, Assistent/MCP,
Einstellungen) vier Fälle prüfen und testen: (1) Falscheingabe (Text statt Zahl, ungültiges Datum/Enum/UUID,
Sonderzeichen, überlang) → Validierungsfehler statt 500 und nie stilles 0/nil; (2) leer ("", Leerzeichen,
Param fehlt) → bewusster Default, Pflichtfeld abgelehnt, Bestandswert nicht still gelöscht; (3) negativ
(-5, Unicode-Minus, "(5)") → erlaubt oder abgelehnt mit Begründung, Vorzeichenkonvention eingehalten, bei Mengen,
Preisen, Prozenten, Laufzeiten abgelehnt; (4) Komma und Dezimalstellen ("1,5" vs. "1.5" je Locale, "1.234,56",
"1,2345678", "0,005") → Parsen nur über den gemeinsamen Money/Number-Helper (kein `to_f`/`to_d` auf Rohtext),
Rundung nach Währung mit benanntem Modus, gespeichert = angezeigt, unverändertes Absenden ändert nichts.
Prüffragen: Welche Stelle parst die Eingabe, und ist es für Web, API und Import dieselbe? Gibt es je Fall einen
Test mit der konkreten Eingabe? Was zeigt das Formular nach dem Fehler (Wert bleibt stehen, L6)?
Beispiele: upstream 4184 (JPY-Rundung beim unveränderten Absenden); L1-Nachträge zu führenden Nullen und UUIDs.

**L34 Funktioniert die Funktion überhaupt? (neu 21.10., Owner-Vorgabe).**
Wer eine Funktion bearbeitet (Daten, Cache, Rechte, Markup dahinter), prüft vorher auf aktuellem main und
nachher auf dem Branch, ob sie für den Nutzer sichtbar funktioniert: im echten Browser oder per Systemtest,
der das Endergebnis prüft (gezeichnetes Diagramm, angezeigter Wert), nicht nur, dass Markup oder ein Frame
geladen wurde. Ist sie auf main schon kaputt, gehört das in den Thread und in den PR (eigenes Issue/eigener
Fix oder bestehenden PR nennen), statt nur die Daten dahinter zu ändern. Prüffragen: Habe ich die Funktion
auf main mit eigenen Augen oder einem Systemtest auf das Endergebnis gesehen? Würde einer meiner Tests rot,
wenn die Anzeige leer bleibt? Screenshot vorher/nachher zeigt die Funktion, nicht nur das Umfeld?
Beispiel: Sidebar-Sparklines waren seit upstream 355 (26.11.2025) leer, weil time_series_chart_controller
Container unter 50×50 px überspringt (Sidebar 32×12/32×20). Unsere upstream PRs 3997, 4207 und 4338 haben
Cache, Frames und Kontoauswahl der Sparklines geändert, ohne das zu bemerken; der Maintainer fand es auf 4338
(Fix upstream 4361). Unsere Tests prüften nur `[complete]` und `data-controller`, nie ein gezeichnetes `svg path`.

**Erweiterungen bestehender Lektionen:**
- L6: Stimulus disconnect() räumt Listener, Timer und Body-Styles auf; fetch mit Timeout; data-targets statt
  querySelector; Turbo.visit statt window.location; Bedienelemente nicht nur per Hover sichtbar (Tastatur).
- L7: Tests nach `private` werden in Minitest nie ausgeführt (3215, 3474); bei N+1-Fixes Query-Count-Test.
- L5: schema.rb nur mit eigenen Änderungen (kein Rauschen anderer Rails/PG-Versionen); NOT NULL nur mit Default oder Backfill.
- L3: SSRF und Open Redirect bei Nutzer- oder Provider-URLs; keine ungepinnten Downloads in CI; Finanzdaten an
  externe KI nur mit ausdrücklicher Freigabe.
- L8: Rails.logger → DebugLogEntry.capture ist der häufigste Einzelbefund in Provider-PRs (23).
- L4: bare `return` im transaction-Block committet; pluck dann update_all ist TOCTOU.
- Hinweis: Die meisten Maintainer-Zurückweisungen sind Prozessgründe (veraltet, Duplikat, nicht abgesprochen,
  offene Bot-Threads, kein Rebase), nicht Code. L17, L19, L20 deshalb vor dem Öffnen eines Upstream-PRs prüfen.

## Nachträge
(Neue Befunde hier mit Datum, PR und zugeordneter Lektion anhängen.)
- 07.10. (Broadcast-Prüfung Provider-Panels): neue Lektion L24 (L23 ist schon im Passkey-Nachtrag vergeben);
  L2 ergänzt: Broadcasts/Streams zählen als eigener Weg in der Wege-Tabelle.
- 07.10. (Prüfung aller offenen PRs, 75 neue Befunde, Liste in befunde-2026-10-07.md):
  - L1 geschärft: Jede neue Spalte oder neuer Aktionswert MUSS in Family::DataExporter, Family::DataImporter
    und, bei Regeln, im CSV-RuleImport/Template stehen; IDs (Kategorie, Händler, Tag) im Export als Namen,
    beim Import neu auflösen; Roundtrip-Test in eine fremde Familie. Durchgerutscht in 3020, 4013, 4018,
    3510, Fork 40, 80.
  - L2 geschärft: Familienweite Insights, Push und Sparklines nur über Konten, die jedes aktive Mitglied sehen
    darf (Muster AccountReleaseGenerator); Cache/ETag mit viewer. Durchgerutscht in 3573, 3997, Fork 64, 15.
    API v1 update/destroy/trades/valuations brauchen writable_by wie create (4000, Fork 35, 37).
    Assistant-Funktionen zählen als Weg (4005: Kategorien/Tags per Chat für Gäste).
  - L5: Migration[7.2] steht noch in 3242, 3261, 3340, 3378, 3498, 3510/3511: vor jedem Push grep auf
    "Migration\[7" im Diff.
  - L11: neue Keys nur in en in 3264, 3361, 3378, 3502, 3573, 3098, 3340, 3777, 3518: vor jedem Push
    für jede neue en-Datei-Zeile die de-Datei prüfen.
- 07.10. (PR 4005, behoben in 2a1939e): L2 geschärft: Eine Prüfung beim Auslösen (publish, apply) gilt nur,
  wenn das Objekt bis zum Job nicht mehr änderbar ist. Verschachtelte Schritt-Controller (upload, mappings,
  rows, configuration) sperren nach dem Auslösen oder prüfen im Job erneut. Durchgerutscht in 4005
  (Gast stellt Zuordnung nach dem Publish auf „neu anlegen“, Job legt Kategorien an).
- 07.10. (Fork 72, behoben in d0ba832): L6 geschärft: Hintergrund-Jobs senden nie `broadcast_refresh` an die
  Familie (voller Morph löscht offene Formulare und schließt Drawer, auch beim Auslöser selbst), sondern den
  Sync-Toast (Muster Family::SyncCompleteEvent) oder gezielte Replaces. L2: Kategorisier-Assistent
  (create, assign_entry) als eigener Weg für manuelle Änderungen vergessen; grep auf `bulk_update!` gehört
  zur Wege-Liste. L14: Paar-Abfragen (Regel × Regel) durch einmal geladene ID-Mengen ersetzen, Regeln ohne
  Wirkung auf das Ergebnis gar nicht erst abfragen; Query-Count-Test (L7) dazu.
- 07.10. upstream PR 3264 (3 Befunde behoben, Commit 0ead755):
  - L7 geschärft (neue Art): Ein neuer Test darf einen bestehenden Bug nicht als „Erfolg“ festschreiben.
    Bei Tests für Sicherheitswege (Passwort, MFA, Schlüssel) auch den Negativfall testen (falsches/leeres
    aktuelles Passwort, Bestätigung abweichend). Falle: `has_secure_password validations: false` schaltet
    auch password_challenge- und Bestätigungsprüfung ab; hier wurde das Passwort ohne das alte geändert.
  - L1: has_secure_password ignoriert ein leeres Passwort, `update` meldet trotzdem Erfolg; leeres
    Passwort ablehnen, bevor Audit/„Erfolg“ geschrieben wird.
  - L11: Key creation_failed nur in en; in alle api_keys-Locales mit create-Abschnitt nachgetragen.
- 07.10. (PR 3221, Backfill-Liste ohne Fio/Monobank/Coinspot, L3/L5 durchgerutscht): Prüffrage geschärft:
  Jede Liste, die „alle Modelle mit X“ aufzählt (Backfill-Manifest, Export, Redaction), braucht einen Test,
  der über ALLE Modelle iteriert (eager_load + descendants), nicht nur über die schon gelisteten. Versions-
  oder Cache-Nummern, die bei Listenänderung steigen müssen, per Digest-Test erzwingen.
- 07.10. upstream PR 3020 (1 Befund behoben, Commit 81bae74):
  - L1 (bekannte Art, durchgerutscht): IDs stecken nicht nur in einfachen Aktionswerten, sondern auch in
    JSON-Werten (split_transaction: category_id/merchant_id/tag_ids je Zeile). Prüffrage geschärft: jeden
    JSON-/Array-Wert einer neuen Aktion auf verschachtelte IDs durchsuchen. Im Export verschachtelte Werte
    als Objekt statt JSON-String schreiben: der CSV-RuleImport entfernt \" in Strings und zerstört sonst
    Namen mit Anführungszeichen. Alte Exporte mit Roh-IDs über die Import-Zuordnungen (mapped_id) auflösen,
    fremde IDs verwerfen statt den ganzen Import scheitern zu lassen. Roundtrip-Test auch mit Sonderzeichen.
- 07.10. (upstream PR 3189, behoben in d452f1558): L2 + L3 geschärft: Wer ein bestehendes Feld neu verschlüsselt
  (oder die Verschlüsselung erst aktiv schaltet), prüft alle Lookups auf dieses Feld mit einer Klartext-Altzeile
  (Login Web/API/SSO-Link/OIDC, Passwort-Reset, Einladungen, MCP, Jobs), je ein Test, der ohne Fix rot ist.
  extend_queries greift nicht bei `encrypts ... downcase: true` plus `normalizes` (User#email). Rückfall-Suche nur
  exakt (Index) und nur für wohlgeformte Werte, damit Ciphertext nie als Eingabe trifft.
- 07.10. PR 3573 (behoben, Commit d437ec4):
  - L2: Insight-Generator nahm alle verbundenen Konten der Familie; jetzt nur Konten, die jedes aktive Mitglied
    sehen darf (Muster AccountReleaseGenerator). Rest-Lücke bleibt bei allen Insights: ein bereits erzeugtes
    Insight bleibt bis zum nächsten Nachtlauf sichtbar, wenn eine Freigabe entzogen wird; IdleCashGenerator
    hat dieselbe Lücke (eigenes Thema).
  - L10 (neue Prüffrage): Wer Valuation-Wegpunkte als Wahrheit liest, prüft, ob der Rechner sie auch so behandelt.
    Der opening_anchor verbundener Konten ist ein Platzhalter (create_and_sync, Brücke im ReverseCalculator),
    kein gemeldeter Saldo.
  - L10: Ein Zahlwert, der nur in facts steht (days_open), veraltet im Text, weil der Body nur bei
    metadata-Änderung neu geschrieben wird; solche Werte nur in der Kennzahl zeigen, nicht im Fließtext.
  - L11: de-Keys ergänzt.
- 07.10. Fork PR 64 (4 Befunde behoben, Commit d0b33d4):
  - L2 (bekannte Art, durchgerutscht): AccountShortfallGenerator nahm alle Konten der Familie; jetzt nur Konten,
    die jedes aktive Mitglied sehen darf. Prüffrage geschärft: Wenn ein Generator einen anderen unterdrückt
    (CashFlowWarning tritt zurück), muss die Unterdrückung dieselbe Kontomenge nehmen, sonst warnt keiner.
    Insight-Links prüfen den Viewer, Broadcast-Renders (ohne Current.user) aber nicht kaputtmachen.
  - L10 (neue Prüffrage): RecurringTransaction.accessible_by verlangt BEIDE Enden einer Umbuchung. Für Salden
    eines sichtbaren Kontos falsch: die Umbuchung zählt trotzdem, wird nur anonymisiert (restricted, ohne Namen,
    Link, IDs). Sonst zeigen Viewer-Ansicht und Familien-Insight verschiedene Salden.
  - L2: Neuer API-Endpunkt einer Preview-Funktion braucht require_preview_features_for_api (jetzt im BaseController).
  - L15: 403 (Scope/Preview) in rswag, nullable IDs dokumentiert, openapi neu erzeugt.
- 07.10. (upstream PR 4000, Commit 7a66fc6): Beide 4000-Befunde aus befunde-2026-10-07.md behoben (L2).
  API update/destroy für Buchungen sowie Trades/Bewertungen create/update/destroy prüfen jetzt Freigaben über
  einen gemeinsamen Helfer `accounts_with_permission(:read|:annotate|:write)` im Api::V1::BaseController.
  L2 geschärft: Annotate-Regeln als Erlaubt-Liste (notes, category_id, merchant_id, tag_ids), nie als Sperrliste,
  sonst rutscht jedes neue Feld durch; Rechte-Stufe je Action explizit, Default = schreiben. Lesewege
  (index/show) desselben Controllers mitprüfen: Trades/Bewertungen waren auch beim Lesen nur familienweit.
  L7: Tests decken read_only UND read_write ab (dort unterscheiden sich annotatable_by und writable_by)
  und prüfen den 404-Text, nicht nur den Status.
- 07.10. (Fork 35, Commit 3159115): Befund aus befunde-2026-10-07.md behoben (L2, high). API update/destroy für
  Buchungen prüfen Freigaben (update: read_write nur Erlaubt-Liste notes/category_id/merchant_id/tag_ids/
  user_modified, sonst 403; destroy nur owner/full_control). L2 geschärft: Der Pre-Push-Review fand auf demselben
  Weg auch fremde category/merchant/tag-IDs offen (Web-Bulk geschützt, API create/update nicht) → bei jedem Fix
  „fremde IDs“ UND „Freigabe-Recht“ gemeinsam je Weg (Web, Bulk, API, Assistant) abhaken.
  L13: Gleicher Fix steckt in upstream PR 4000 (gemeinsamer Helfer) → vor dem Fix nach Parallel-PRs suchen.
- 07.10. upstream PR 3518 (4 Befunde behoben, Thread „Befunde PR 3518“):
  - L2 geschärft: Hintergrund-Jobs/Syncs ohne User handeln im Namen des Konto-Besitzers; Ziele nur über
    writable_by(owner).visible wie der passende Dialog. Konto ohne Besitzer → nichts automatisch anlegen.
  - Neue Fehlerart (L2/L10): Ablehnen/Lösen eines automatisch erzeugten Objekts muss sich die Ablehnung
    merken, sonst legt der nächste Sync es neu an (FK-Cascade löschte den RejectedTransfer mit). Merken nur bei
    Nutzeraktionen (reject/unlink), nicht bei System-destroy (Konto löschen/mergen). Test: Ablehnen → Sync → nichts neu.
  - L4: Sync-Batches arbeiten mit veralteten Objekten; vor dem Schreiben lock! + Recheck. jsonb-Flags atomar
    mergen (`extra || ?::jsonb`), nicht aus dem In-Memory-Stand überschreiben. Kein `return` im transaction-Block.
  - L14: Erst billig vorfiltern (SQL + vorab geladene IBAN-Menge), dann teure Kandidaten-Query; preload statt
    includes, wenn zugleich joins (sonst EagerLoadPolymorphicError).
  - L11: Gespeicherte Namen über I18n.with_locale(family.locale) und in ALLEN Locales der Geschwister-Keys
    (hier 19), nicht nur en+de. CRLF-Locale-Dateien binär bearbeiten, sonst Ganzdatei-Diff.
- 07.10. (upstream PR 4000, CodeRabbit nach 7a66fc6, behoben in Folge-Commit): `user_modified` stand in der
  Annotate-Erlaubt-Liste; read_write konnte damit allein den Sync-Schutz setzen (L2). Prüffrage geschärft:
  Flags mit Nebenwirkung (Sync-Schutz, Sperren, Lock) gehören nie in eine Annotate-Liste, auch wenn das Web
  sie beim Annotieren nebenbei setzt.
- 07.10. (PR 3221, Nachtrag 2): Fix war lokal grün, Upstream-CI rot, weil die CI den Merge mit main testet und
    main (upstream PR 3827) inzwischen Monobank masked_pan/iban gelöscht hatte. L13 geschärft: Bei Listen/Manifesten
    und bei Branches, die hinter main liegen, vor dem Push `git merge-tree` reicht nicht; main probeweise mergen
    und die betroffenen Tests auf dem Merge-Stand laufen lassen.
- 07.10. Fork 84 (Passwortänderung drosseln, vor dem PR behoben in 3b51536): L7 geschärft: Tests gegen
  Rack::Attack-Zählfenster (fest je Minute) brauchen freeze_time, sonst rot an der Minutengrenze. L3: Sitzungs-
  oder Token-IDs als Drossel-Schlüssel nur gehasht (SHA256) in den Cache. L13: Kommentar „Formular sendet POST“
  war falsch, Rack::MethodOverride läuft vor Rack::Attack (per `bin/rails middleware` prüfen).
- 07.10. upstream PR 3511 (Thread „Befunde PR 3511“, Commits 84e7755, cc295bb, c3cc63f):
  - L1 geschärft: Ein früheres Review (CodeRabbit/Codex, 11.09.) hatte „leere Neulieferung löscht gespeicherten
    Wert“ verlangt, das neue Review das Gegenteil. Regel: Provider-Daten, die eine spätere Lieferung nur
    weglässt (Bank liefert beim Buchen weniger als bei „pending“), nie löschen; nur ein vorhandener neuer Wert
    ersetzt. Wenn ein Bot „stale value“ fordert, prüfen, ob „fehlt“ wirklich „entfernt“ heißt.
  - L5: Dieselbe Migration in Geschwister-Branches immer mit identischem Dateinamen UND Inhalt (3511, 3513,
    3514, 3517 trugen 20260911120000 statt 20260910120000 und eine ältere Fassung der Uniqueness-Migration);
    beim Angleichen per diff gegen den Basis-Branch prüfen. [7.2] → [8.1] in allen IBAN-Migrationen, auch 3510.
  - L13: Fremde Fixes (hier DS::ExpandToggle auf dem Dashboard, angeregt von einem Bot) nicht in einen
    Feature-PR committen, sondern eigener PR; bei offenem Upstream-PR per Revert-Commit entfernen, nicht per Force-Push.
- 07.10. Fork PR 86 (Insights: idle cash + entzogene Freigabe, Pre-PR-Review behoben):
  - L2 (neue Prüffrage): Sichtbarkeit, die sich nachträglich ändern kann (Freigabe entzogen, Mitglied neu,
    Konto verschoben/gelöscht), beim Lesen filtern statt per Callback Zeilen umschreiben. Callbacks verpassen
    delete_all/insert_all und Konto-Löschung und überschreiben Nutzerzustand (acknowledged kam beim
    Unshare/Reshare als ungelesen zurück). Den Filter in den Standard-Scope (`visible`) legen und die übrigen
    Wege einzeln abhaken: Badge, Mark-read per update_all, find per ID (acknowledge/unacknowledge), Assistant
    include_acknowledged, Push-Zustellung, Job-Expiry (nach Status, nicht nach dem gefilterten Scope).
  - L14: JSON-ID gegen Primärschlüssel nie per `id::text` vergleichen (kein Index), sondern auf uuid casten,
    mit CASE + Regex gegen fehlerhafte Werte.
  - Offen, eigenes Thema: CashFlowWarning, SubscriptionAudit, SpendingAnomaly, MaintainedGoalDepleted
    rechnen über alle Familienkonten (auch private).
    Erledigt in Fork PR 89 (07.10.): alle Summen-Generatoren (auch SavingsRate, NetWorth, Budget) über
    Konten, die jedes aktive Mitglied sehen darf. L2-Prüffrage geschärft: Generatoren laufen im Job ohne
    Current.user; IncomeStatement/BalanceSheet/Budget fallen dann auf ALLE Konten zurück, also Konto-Scope
    immer explizit übergeben. Persönliche Budgets gehören nicht in den Familien-Feed.
- 07.10. Fork-Branch „Abmelden nach Passwortänderung“ (Commit b43d5fa, eigenes /code-review vor dem PR):
  - L4 (bekannte Art, beim Bauen durchgerutscht): Token-Widerruf lief zuerst in after_update_commit, also
    nach dem Freigeben der User-Zeilensperre. Ein gleichzeitiger /api/v1/auth/refresh (sperrt dieselbe Zeile
    per with_active_lock!) konnte dazwischen ein neues Token ausstellen, das das update_all nicht mehr sah.
    Prüffrage geschärft: Widerruf oder Sperre, die gegen einen parallelen Ausstell-Weg wirken soll, läuft in
    derselben Transaktion bzw. unter derselben Sperre wie der Ausstell-Weg (hier after_update statt
    after_update_commit).
- 07.10. upstream PR 3034 (2 Befunde behoben, Commit 323f384):
  - L2 (bekannte Art, durchgerutscht): Ein familienweiter Schalter (auto_match_transfers_disabled) war für
    Mitglieder und Gäste offen und löschte beim Ausschalten alle offenen Vorschläge, auch zwischen fremden
    privaten Konten. Prüffrage geschärft: Jede Action, die ein Family-Feld schreibt oder familienweit löscht,
    braucht require_admin! plus Test für Mitglied UND Gast; die View zeigt das Bedienelement dann nur lesend.
  - L9 geschärft (neue Art): Hängt die Zählung einer Buchung von einer anderen Tabelle ab (hier offener
    Transfer statt kind), ändert ein Schreiben dort entries_cache_version nicht. Für jede neue
    Ausschlussbedingung in Berichts-/Summen-SQL fragen: Welche Schreibwege ändern sie, und bumpen sie
    den Cache-Key? Lösung hier: Transfer-Callbacks setzen updated_at beider Bein-Entries
    (update_all, nicht bei destroyed_by_association). Zusätzlich: Ändert sich das SQL hinter einem Cache,
    bekommt JEDER Key mit diesem SQL eine neue Version (auch unversionierte wie family_stats), sonst
    liefert er nach dem Deploy alte Werte. Test mit echtem MemoryStore, der ohne Fix rot ist.
- 07.10. Fork 87 (Passwortregeln bei Änderung/Reset, vor dem PR behoben): L11 geschärft: neue Fehler-Keys in
  allen Locales anlegen, für die es die gleiche Aussage schon gibt (hier die Admin-Texte password_missing_* in
  ca, fr, pl, pt-PT, ru, tr, uk), nicht nur en + de. Achtung: `i18n-tasks normalize` ohne -p schreibt alle
  Locale-Dateien um; nur gezielt einsetzen und den Diff vor dem Commit prüfen.
- 07.10. upstream PR 3510 (Commit 8266281, Thread „Befunde PR 3511“): L1 durchgerutscht trotz Vorbild zwei Zeilen
  darunter (website_url mit key?-Schutz). Prüffrage geschärft: Jedes neue Feld im DataImporter mit
  `if data.key?(...)` zuweisen, sobald der Datensatz per Name/Mapping auf einen bestehenden trifft; Test „Datei ohne
  Key behält Wert“ UND „explizites null löscht“.
- 07.10. upstream PR 3340 (Commit 0468689, Thread „Befunde PR 3340“): L5 und L11 durchgerutscht. L5 geschärft:
  Bei Migration[7.x] in einem offenen PR Version auf die aktuelle heben UND Zeitstempel hinter die neueste
  main-Migration legen (main vorher mergen, schema.rb-Version mitziehen); Wiederholung auf einer DB mit altem
  Zeitstempel muss ein No-op sein (up mit valid_index_exists?-Guard prüfen). L11 geschärft: neuen Key in jede
  Locale-Datei setzen, die den Geschwister-Key schon übersetzt, mit i18n-Test nach Muster
  test_bills_notices_heading_exists_for_each_bills_locale (fallback: false), der ohne die Übersetzung rot ist.
  - L4 (CodeRabbit auf Fork 88, behoben in 0d42eb0): Es gibt zwei Refresh-Wege. Der eigene /api/v1/auth/refresh
    sperrt den User, Doorkeepers /oauth/token sperrt nur das alte Token. Ein Refresh, der das alte Token schon
    gesperrt hatte, konnte ein neues Token committen, das der Widerruf in der Transaktion nicht sah. Lösung: zweiter
    Widerruf in after_update_commit. Prüffrage geschärft: Bei einem Widerruf ALLE Ausstell-Wege mit ihrer Sperre
    aufzählen (auch Gem-interne wie Doorkeeper-Grant-Flows). Wo ein Weg die eigene Sperre nicht nimmt, nach dem
    Commit noch einmal widerrufen.
- 07.10. upstream PR 3190 (3 Befunde, Commit f643530):
  - L3 geschärft (Timing/Enumeration): Ein eigener Login-Helper neben `authenticate_by` muss auf JEDEM Weg genau
    einen bcrypt-Digest kosten: Treffer mit Passwort, unbekannte E-Mail UND SSO-only-User (password_digest nil,
    dort hasht Rails' authenticate nicht). Leeres Passwort auf allen Wegen ohne Hash ablehnen, Nicht-String-Passwort
    per to_s statt 500. Test: `BCrypt::Password.expects(:create).once` je Weg, ohne Fix rot.
  - L2 (bekannte Art, durchgerutscht): Der Timing-Fix galt nur für Web-Login und OIDC; API-Login (/api/v1/auth/login)
    hatte die gleiche Lücke über find_by_email + authenticate. Alle Login-Wege auf denselben Helper legen.
  - L2: Ein Lookup-Fix (find_by_email für Klartext-Altzeilen) muss auch reine Existenz-Prüfungen (`exists?`) erfassen,
    hier die OIDC-Link-Seite. Prüffrage: grep nach `exists?(email`/`find_by(email` im ganzen app/.
  - L7/Befund-Prüfung: Der Eindeutigkeits-Befund (Duplikat per JIT) war falsch: der Uniqueness-Validator wird von
    extend_queries erweitert, find_by mit normalizes nicht. Befunde erst per Test nachstellen, bevor Code entsteht;
    nicht reproduzierbare Befunde bekommen nur einen Regressionstest.
- 07.10. upstream PR 3261 (2 Befunde behoben, Commit 8afd5c8, Thread „Befunde PR 3261“):
  - L2 (bekannte Art, durchgerutscht): Der PR kürzte die TTL von Doorkeeper-Tokens, aber /api/v1/auth/refresh
    stellte für JEDES Refresh-Token ein neues 30-Tage-Token aus, auch für Drittanbieter-/MCP-Apps. Prüffrage
    geschärft: Wer eine Lebensdauer, Sperre oder einen Widerruf für Tokens ändert, zählt alle Ausstell- UND
    Verlängerungswege auf (/oauth/token, eigene Refresh-Endpunkte, issue_token!, SSO-Exchange) und prüft je Weg,
    ob er die neue Regel umgeht. Eigene Endpunkte mit fester Laufzeit nur für die eigene App (Anwendung UND
    Geräte-Bindung prüfen), je Bedingung ein Test, der allein ohne diese Bedingung rot ist.
  - L13: Kommentar „Doorkeeper wendet beim Refresh access_token_expires_in an“ war falsch; der Refresh-Grant
    übernimmt expires_in des alten Tokens (RefreshTokenRequest#create_access_token). Annahmen über Gem-Verhalten
    im Gem-Quelltext prüfen, bevor sie in Kommentare oder PR-Texte gehen.
  - L5: Migration[7.2] → [8.1] (siehe grep-Regel oben).
- 07.10. upstream PR 3361 (1 Befund behoben, Commit bf159b2, Thread „Befunde PR 3361“):
  - L11 (bekannte Art, durchgerutscht): `create_rule`, `create_rule_title`, `create_rule_subtitle` nur in
    transactions/en.yml, obwohl de.yml existiert; der neue Drawer-Abschnitt erschien deutschen Nutzern englisch.
    Die en+de-Prüffrage oben reicht; sie war beim Bau nicht gelaufen. Regressionstest-Muster: Ansicht mit
    `locale: "de"` rendern und den deutschen Text per assert_select prüfen (rot ohne de-Key, weil die Fallback-
    Kette en liefert und kein Fehler entsteht).
- 07.10. upstream PR 3378 (2 Befunde behoben, Commits eb4ec6a, 0d07523, Thread „Befunde PR 3378“):
  - L5 (bekannte Art, durchgerutscht): neue Migration noch mit `Migration[7.2]`. Prüffrage bleibt: vor dem PR
    `grep -L "Migration\[8.1\]"` über die Migrationen des Diffs.
  - L11 geschärft: Neue Keys nicht nur in en+de, sondern in jeder Locale, die den Nachbar-Key schon übersetzt
    (hier 15 bzw. 18 Sprachen), mit Test, der über alle Locales mit Nachbar-Key iteriert. Neu: Begriffe aus der
    jeweiligen Locale übernehmen (z. B. household_title statt wörtlich „Familie“, merchant_label der Locale), sonst
    zeigt dieselbe Seite zwei Wörter für dasselbe. Beim Ersetzen per Skript nur die neuen Zeilen treffen
    (hier hätte ein globales Ersetzen eine bestehende pt-BR-Zeile geändert).
- 07.10. Fork-PR „Reserve Sure client names in OAuth dynamic registration“ (Thread „Fälschbarer App-Name Sure Mobile“, 3 Befunde aus /code-review vor dem PR behoben):
  - L1 geschärft (Normalisierung): Ein Namensabgleich über zusammengeklebte Wörter (`words.join.include?("suremobile")`)
    traf auch „Measure Mobile“. Prüffrage: Bei Sperr- oder Erkennungslisten auf Namen immer Falsch-Positive mit
    Wort-Enden/-Anfängen testen (Measure, Surefire) und unsichtbare Zeichen (\p{Cf}, z. B. U+200B) vor dem Zerlegen entfernen.
  - L2 (bekannte Art): Der Seed legte die Mobile-App weiter mit eigener Suche an, nicht über die gehärtete Methode.
    Prüffrage: Seeds und Rake-Tasks gehören in die Wege-Tabelle.
  - L11 (bekannte Art, durchgerutscht): Neuer Key zuerst nur en+de, Nachbar-Key gab es aber auch in ru, ca, pl, tr, uk.
- 07.10. Fork-PR „Passkey nur mit MFA-Code“ (6 Befunde aus /code-review vor dem PR behoben, Thread „Passkey ohne Bestätigung“):
  - L7 (bekannte Art): Geänderter Endpunkt wurde auch von Test-Helfern in anderen Dateien aufgerufen
    (mfa_controller_test, passkey_sessions_controller_test); 21 Fehler in der vollen Suite. Prüffrage geschärft:
    Wer einen Endpunkt strenger macht, sucht mit grep über test/ nach allen Aufrufern des Pfad-Helpers.
  - Neu L23 Einmal-Nachweise erst direkt vor der Wirkung verbrauchen: Ein TOTP- oder Backup-Code, der vor einer
    Browser-Zeremonie (WebAuthn-Dialog) geprüft wird, ist bei Abbruch verloren. Prüfen dort, wo gespeichert wird.
  - L8 (bekannte Art): verify_otp? faltet „schon benutzt“ in „ungültig“; für Nutzer verify_otp nutzen und
    :replayed eigens melden (Muster MfaController#create).
  - L3 erweitert: Ratenlimit für Code-Prüfungen hinter Login je Nutzer (Rails rate_limit by: Current.user.id),
    nicht je Session-Cookie; mehrere Sessions vervielfachen sonst das Rate-Budget.
  - L13 (bekannte Art): Platzhalter nannte nur den Authenticator-Code, der Server nimmt auch Backup-Codes.
  - L1 (Formular): Feld im form-Scope (webauthn_credential[code]) muss zum gelesenen Param passen.
- 07.10.2026, upstream PR 4017 (Maintainer-Kommentar, keine Bugs), behoben in 8e7b030:
  - L14 (bekannte Art, Prüffrage geschärft): Datumsfortschreibung in einer Schleife (`terms += 1 while …`)
    statt direkt aus der Monatsdifferenz gerechnet; Laufzeit wächst mit dem Alter des Kontos.
    Prüffrage: „Läuft eine Schleife über Zeit (Tage, Monate, Laufzeiten), die sich direkt ausrechnen lässt?“
  - L1/L7 (bekannte Art): Summen über Konten ohne Test mit zweiter Währung; Test mit EUR-Konten in einer
    USD-Familie ergänzt, rot ohne Umrechnung. Prüffrage: „Gibt es zu jeder neuen Summe über Konten einen
    Test mit einem Konto in Fremdwährung?“
- 07.10. upstream PR 4003 (Maintainer-Hinweis behoben, Commit 1c5bb97, Thread „jjmata-Hinweis PR 4003“):
  - L4 erweitert (Zeitfenster Anzeige → Klick): „Alle als gelesen markieren“ setzte das Wasserzeichen auf die
    Klickzeit und erfasste so Buchungen, die ein Sync nach dem Laden der Seite angelegt hatte. Prüffrage: Wirkt eine
    Sammelaktion auf „alles, was der Nutzer gesehen hat“, muss die Seite ihren Ladezeitpunkt (oder die gezeigten IDs)
    mitschicken; der Server begrenzt darauf, deckelt auf jetzt und setzt nichts zurück.
  - L4 (bekannte Art, durchgerutscht, CodeRabbit auf Fork #74): Das „nie zurücksetzen“ verglich mit dem Wert im
    Speicher (`[as_of, read_before].max` + update_column). Zwei Tabs gleichzeitig konnten ihn trotzdem zurücksetzen.
    Prüffrage: Monotone Werte (Wasserzeichen, Zähler) immer in SQL begrenzen (GREATEST/LEAST im UPDATE), nie mit dem
    geladenen Attribut vergleichen. Fix: Commit nach 1c5bb97.
- 07.10. Prüfung aller offenen PRs gegen L16–L22 (37 Code-Befunde, siehe befunde-2026-10-07-neu.md):
  - L18 geschärft (häufigste neue Art, 10 Befunde): Ändert ein PR Verhalten für BESTEHENDE Installationen
    (Default entfernt, Tokens widerrufen, Rechte enger, Migration bricht bei Altdaten ab, Auth eingeschaltet),
    braucht er einen Upgrade-Hinweis mit konkretem Weg (Befehl/SQL) in docs/hosting und PR-Text. Prüffrage:
    „Was sieht ein Self-Hoster, der nur `docker compose pull && up` macht, und woher weiß er, was zu tun ist?“
    Beispiele: upstream 3221/3190 (SECRET_KEY_BASE), 3261 (OAuth-Widerruf), 3340 (Migration bricht bei Duplikaten
    ab statt zu bereinigen), 3794/3994 (Rechte), Fork #22 (WEBUI_AUTH).
  - L18 erweitert: CSP-/Host-Listen nicht nur aus ENV bauen, wenn die Einstellung auch in der UI geändert werden
    kann (upstream 3246: PLAID_ENV vs. Provider-Einstellung, PostHog-Survey ohne Key).
  - L2 erweitert (Step-up-Schutz): Wer eine Aktion mit einem zweiten Faktor absichert, prüft jeden Weg, der den
    Faktor selbst ändert (abschalten, neu einrichten). Fork #90: Passkey braucht MFA-Code, aber `mfa#disable`
    braucht nur die Session. Prüffrage: „Kann ein Angreifer mit nur einer Session den Schutz zuerst abschalten?“
  - L2 erweitert (Sitzungen nach Passwortwechsel): Aufräumen ins Modell, nicht in einen Controller (Fork #88).
  - L21 geschärft: Bevor eine Logik kopiert wird („Mirrors …“), nach bestehendem Helfer suchen (Setting.brand_fetch_icon_url,
    find_or_create_with_name, Transfer.kind_for_account, search_params). Kopien weichen in den Befunden schon
    beim Anlegen ab (3776, 3843, 3719, 3020, 4003, 4013, Fork #54, #87).
  - L22 geschärft: Wenn ein PR viele Abfragen einzeln flickt (3034: ~12 Stellen) oder nur die Anzeige korrigiert
    (3719: kind wird vom Sync überschrieben), fehlt eine zentrale Stelle. Prüffrage: „Gibt es eine Stelle, die
    falsch schreibt, statt vieler, die falsch lesen?“
  - L16 erweitert: Teilergebnis (Paginierungs-Deckel, fehlgeschlagener Upload) nie als Erfolg melden und nie ohne
    DebugLogEntry; sonst schaltet der nächste Sync auf inkrementell und der Rest fehlt für immer (3777, Fork #15).
  - Prozess (L17/L19/L20): upstream #3814 ist Duplikat von #2041; 7 PRs mit CHANGES_REQUESTED brauchen Re-Review;
    20 PRs ohne Maintainer-Zustimmung. Vor neuen Upstream-PRs immer L17/L19 prüfen.
- 07.10. upstream PR 3190, zweite Runde (L18, Commit 9973fc9): Der PR entfernt den mitgelieferten SECRET_KEY_BASE-Default
  und rät „openssl rand -hex 64“. Bestehende Installationen, die dem folgen, verlieren alles, was unter den daraus
  abgeleiteten Schlüsseln verschlüsselt ist. Prüffrage L18 geschärft: Ändert ein PR einen Default, eine Pflicht-ENV oder
  einen Schlüssel, steht in Doku UND an der Fehlermeldung/im Compose-Kommentar ein Upgrade-Hinweis für bestehende
  Installationen (alten Wert behalten, Rotation nur über `previous`). Gilt für Geschwister-PRs mit denselben Commits mit
  (hier upstream PR 3221).
- 07.10. (PR 3221, L18 behoben): Entfernter Standardwert (SECRET_KEY_BASE) ohne Upgrade-Hinweis. Behoben per
  Doku-Commit (Compose-Kommentare + docker.md-Abschnitt „Upgrading …“). Prüffrage: Ändert der PR einen Default,
  den bestehende Installationen nutzen, steht der Upgrade-Weg dort, wo der Betreiber die Fehlermeldung sieht.
- 07.10. upstream PR 3242 (Thread „Befunde PR 3242“, Commits 728eec9, 890f20a):
  - L5: Migration[7.2] → [8.1] (Befund aus der Prüfung vom 07.10.); vor jedem Push grep auf "Migration\[7" im Diff.
  - L7 geschärft: Eine neue Sitzungs-/Token-Ablaufregel (hier 30 Tage Inaktivität) bricht fremde Tests, die nach
    `sign_in` per `travel_to` weit springen (loan_payoff_chart_test von main: Login-Umleitung, CI rot). Bei
    Ablauf-/TTL-Logik `grep -rn travel_to test/system test/controllers` und solche Tests im Zeitsprung anmelden
    lassen; nach Merge von main die Systemtests lokal laufen lassen, nicht nur Unit-Tests.
  - L21 (Lektionen-Prüfung, Datei befunde-2026-10-07-neu.md): ReadsController#filter_params war eine Handkopie von
    TransactionsController#search_params und schon auseinandergelaufen (amount_operator-Bereinigung fehlte). Behoben
    in eefef46 mit Transaction::Search.clean_filters für beide. Prüffrage bleibt: Kommentar „Mirrors X“ heißt teilen, nicht kopieren.
- 07.10. upstream PR 3261, Runde 2 (L18-Befund behoben, Commit 038008c):
  - L18 (bekannte Art, durchgerutscht): Eine Migration, die bestehende Tokens widerruft, und eine kürzere
    Token-Laufzeit brauchen einen Upgrade-Hinweis in der Hosting-Doku (hier docs/hosting/mcp.md + ai.md),
    inklusive „nicht per Rollback umkehrbar“, wenn down IrreversibleMigration wirft.
  - L13 (neue Prüffrage): Ändert ein PR eine Laufzeit oder ein Protokollverhalten, die Discovery-Metadaten
    mitprüfen (hier grant_types_supported und Registrierungsantwort ohne refresh_token): Clients richten sich
    nach den Metadaten, nicht nach dem tatsächlichen Verhalten des Token-Endpunkts.
  - L2/L3 (neue Art): Doorkeeper widerruft das alte Refresh-Token erst bei der ersten Nutzung des neuen
    Access-Tokens über Doorkeeper::OAuth::Token.authenticate. Eigene Token-Prüfungen mit AccessToken.by_token
    (MCP, API v1) überspringen das; dort revoke_previous_refresh_token! aufrufen. Prüffrage: Ersetzt eigener
    Code einen Gem-Helfer, welche Nebenwirkungen des Helfers fallen dann weg?
- 07.10. upstream PR 3340 (Commit e7db276, Thread „Befunde PR 3340“, Befund aus befunde-2026-10-07-neu.md): L18
  durchgerutscht. Prüffrage geschärft: Ein Unique-Index für einen Zustand, den der behobene Bug selbst erzeugt,
  darf beim Upgrade nicht mit IrreversibleMigration abbrechen (Docker-Entrypoint startet dann nicht). Duplikate in
  der Migration bereinigen (Regel, welcher Eintrag bleibt, mit Owner-Entscheidung, gelöschte IDs per `say`
  protokollieren) und die Bereinigung als eigene Methode testen (CONCURRENTLY läuft nicht in der Test-Transaktion).
- 07.10. upstream PR 3020 (L21 behoben, Commit f3c245e):
  - L21: SplitsController#build_splits war eine Kopie der ID-Prüfung aus Rule::ActionExecutor::SplitTransaction
    („mirrors …“-Kommentar) und wich beim Händler-Scope schon ab. Jetzt eine gemeinsame Klasse
    Entry::SplitReferences. Prüffrage geschärft: Ein „mirrors X“-Kommentar ist ein Signal zum Extrahieren;
    bewusste Unterschiede (hier Händler-Scope mit/ohne Nutzer) als Parameter übergeben und dort dokumentieren.
- 07.10. upstream PR 3034, Befund B4 (L22, behoben in 88aed49):
  - L22 geschärft: Wer eine neue Bedeutung neben eine bestehende Spalte stellt (hier: offener Transfer =
    Umbuchung, obwohl kind "standard"), definiert sie EINMAL als Scope/SQL-Helfer plus Ruby-Prädikat und
    ersetzt dann per grep alle Stellen, die die alte Spalte prüfen (where kind, TRANSFER_KINDS,
    UNCATEGORIZED_EXCLUDED_KINDS, transfer?). Durchgerutscht: Uncategorized-Scope und -Filter, gemischte
    Typfilter (Ausgabe+Umbuchung), Tagessummen im Helper, InvestmentFlowStatement.
  - L14: NOT IN/IN mit unkorreliertem Subselect (UNION ALL) statt korreliertem EXISTS mit OR, damit Postgres
    die IDs einmal hasht.
  - L3/Brakeman: Kein #{...} in where-Strings, auch nicht für Konstanten-SQL; stattdessen Scope + .or(...).
    Brakeman meldet es sonst als SQL-Injection und die CI wird rot.
- 07.10. Fork #91 (2 Befunde aus befunde-2026-10-07-neu.md Teil 1 behoben, Commit 993a41a, Thread „Fälschbarer App-Name Sure Mobile“):
  - L1 geschärft (Normalisierung, bekannte Art): NFKC faltet keine Doppelgänger aus anderen Schriften; „Ѕurе Mobile“ (kyrillisch Ѕ/е)
    kam durch die Namenssperre. Prüffrage: Bei jeder Namens-/Marken-Sperre zusätzlich kyrillische, griechische und armenische
    Doppelgänger der betroffenen Buchstaben testen und vor dem Vergleich auf Latein abbilden (kleine Map, kein Gem nötig).
  - L13 (bekannte Art): Branch von upstream main abgezweigt, Fork-main zwei Commits dahinter, dadurch ca. 180 fremde Zeilen im
    Fork-PR. Prüffrage: Fork-PR-Branch auf origin/main setzen (oder Fork-main vorher synchronisieren), Diff gegen die PR-Basis prüfen.
- 07.10. upstream PR 3510 (B3 aus befunde-2026-10-07-neu.md, Commit d7696b0, Kette 3511/3512/3515/3516/3518):
  L22: Eindeutigkeit einer externen Kennung (IBAN) nie ohne Fachprüfung festlegen: Revolut/Wise haben eine
  IBAN für mehrere Währungskonten, Gemeinschaftskonten kommen über zwei Zugänge. Prüffrage: „Kann dieselbe
  Kennung real mehrere Datensätze tragen?“ Folgefehler: Sync-Warnung bei JEDEM Lauf → bekannte Konflikte vorab
  prüfen und nur einmal loggen. Index-Änderung nach schon ausgeführter Migration immer als NEUE Migration
  (Produktiv-Build), in jeder Kettenkopie; find_by auf nicht mehr eindeutige Spalten durch Auswahl ersetzen.
- 07.10. upstream PR 3994 (Commit 62e0843, Thread „PR 3994: SSO-Registrierung“, Befund aus befunde-2026-10-07-neu.md Teil 1): L18
  (bekannte Art, durchgerutscht): Die neue Regel „SSO legt bei invite_only/closed nur für Eingeladene Konten an“ änderte
  Verhalten für bestehende Installationen (z. B. invite_only plus ALLOWED_OIDC_DOMAINS als Selbst-Onboarding), aber
  docs/hosting/oidc.md beschrieb JIT weiter nur über AUTH_JIT_MODE und ALLOWED_OIDC_DOMAINS. Behoben mit Abschnitt
  „Onboarding mode“ und Upgrade-Hinweis in oidc.md §3.3 plus Verweis in docker.md/hetzner.md. Prüffrage L18 geschärft:
  Verschärft ein PR eine Zugangs- oder Registrierungsregel, die Doku-Seite des betroffenen Mechanismus (hier SSO/JIT,
  nicht nur die Onboarding-Seite) im selben PR anpassen und dort sagen, was Bestandsinstallationen tun müssen.
  Der Vorschlag „JIT in die Default-Familie zulassen“ wurde bewusst nicht übernommen (Owner-Entscheidung: nur persönliche
  Einladung).
- 07.10. PR 3573 (zweite Runde, Commit 47ac1c7):
  - L16 (neue Prüffrage): Saldo-Schnappschüsse eines Providers (current_anchor/reconciliation) sind Stand zum
    Sync-Zeitpunkt, nicht Tagesende. Wer sie mit dem Buchungsjournal vergleicht, prüft: Buchungen desselben Tages
    nach dem Sync, Vormerkungen im Schnappschuss, Passiv-Vorzeichen. Anker nur auf exakten Tagen (ohne Buchungen).
  - L22: Erster Ansatz (Tage mit Buchungen ausblenden, dann pauschale Toleranz) hat echte Lücken verdeckt; die
    Review-Runden zeigten das. Prüffrage: Verliert der Fix Erkennung, die vorher richtig war? Test mit Lücke kleiner
    als die Tagesumsätze.
- 07.10. (Fork 35, Commit 5bde9b4): Befund B8 aus befunde-2026-10-07-neu.md behoben (L2). `user_modified` stand noch
  in der Annotate-Erlaubt-Liste der API; read_write konnte so den Sync-Schutz für fremde Buchungen setzen.
  Durchgerutscht, weil beim Angleichen an upstream PR 4000 ein älterer 4000-Stand kopiert wurde. Prüffrage
  geschärft: Wer Code aus einem fremden/offenen PR übernimmt, holt vor jedem Push dessen neuesten Kopf
  (git fetch upstream pull/N/head) und vergleicht die übernommenen Dateien.
- 07.10. upstream PR 3034, CodeRabbit-Review auf 88aed49 (3 Befunde behoben in caf1741):
  - L4: Einstellung speichern und davon abhängige Aufräumarbeit (destroy vieler Zeilen) gehören in EINE
    Transaktion, sonst bleibt bei Fehlern ein halber Zustand. Jobs danach außerhalb enqueuen.
  - L1/L22: Wächter auf „noch nicht bestätigt“ (pending?) gehört in jede Methode, die beim Bestätigen
    Daten ableitet; sonst überschreibt ein zweiter Aufruf nachträgliche Nutzeränderungen.
  - L11 geschärft: Pluralformen je Sprache prüfen (pl/ru/uk: one/few/many/other, ro: one/few/other);
    rails-i18n nutzt sie, fehlendes `few` gibt grammatisch falschen Text. Test mit count 2–4.
- 07.10. upstream PR 3246 (Commit 3f5ba6e, Thread „PR 3246: CSP-Befunde“, zwei Befunde aus befunde-2026-10-07-neu.md Teil 1): L18
  (bekannte Art, durchgerutscht): Eine CSP-Allowlist wurde beim Booten aus EINER ENV-Variable gebaut (PLAID_ENV),
  obwohl der wirksame Wert auch aus Settings > Providers (config_value hat Vorrang) oder PLAID_EU_ENV kommt; und
  PostHog-Hosts hingen nur am Analytics-Schlüssel, während die Self-Hosted-Feedback-Umfrage ohne Schlüssel lädt.
  Folge: stille CSP-Blockade (nur Konsolenfehler). Behoben: alle Plaid-API-Hosts erlaubt; PostHog-Hosts per
  Request-Proc mit denselben Bedingungen wie die Views (Analytics + Feedback-Projekt), Test gegen den echten Header.
  Prüffrage L18 geschärft: Leitet ein PR eine Allowlist, Grenze oder Sicherheitsregel aus Konfiguration ab, ALLE
  Quellen des wirksamen Werts aufzählen (ENV, Settings-UI/config_value, EU-/Zweit-Provider, Defaults) und ALLE
  Integrationen, die denselben Dienst laden (hier Analytics UND Feedback-Umfrage). Bedingung aus derselben Stelle
  wie die View lesen, nicht nachbauen; Test prüft den gesendeten Header im Produktions-Zweig.
- 07.10. PR 3776 (Commit d744df1): Befunde B2 aus befunde-2026-10-07-neu.md behoben.
  - L22: Der Fix gegen überschriebene Provider-Logos (#2925) saß nur im Enhancer; der zweite LLM-Weg
    (AutoMerchantDetector Case 2) setzte logo_url weiter ungeprüft und mit roher URL. Prüffrage geschärft: Wer eine
    Invariante am Modell einführt (before_save „nur leeres Logo füllen“), sucht alle Stellen, die das Feld selbst
    setzen (`grep logo_url =`/`logo_url:`), und lässt sie das Feld weglassen, statt es vorab zu füllen.
  - L21: Vierte handgebaute Brandfetch-URL neben `Setting.brand_fetch_icon_url`; jetzt nutzen ProviderMerchant und
    FamilyMerchant den Helfer (Account:560 bleibt außerhalb des PR-Umfangs).
- 07.10. upstream PR 3020 (Maintainer-Wunsch „Design-System nutzen“, DS-Umbau der Split-Felder): Zwei neue Lehren.
  - L6/L21 (bekannte Art, durchgerutscht): Splits-Dialog und Regel-Formular hatten handgebaute Selects/Tag-Picker statt
    StyledFormBuilder, DS::Select, DS::MerchantSelect, DS::TagSelect. Beim Umbau zeigten sich zwei a11y-Lücken der
    DS-Bausteine bei Wiederholung: DS::Select vergab feste ids („category_id_label“), also doppelte ids je Zeile
    (neu: scoped_ids), und Merchant-/Tag-Trigger hatten kein id, auf das `<label for>` zeigt. Prüffrage geschärft:
    Wird ein DS-Baustein in einer Liste wiederholt, Test auf eindeutige ids und gelabelte Steuerelemente je Zeile.
  - Neue Fehlerklasse (L1): Ein virtuelles Feld (attr_accessor `split_rows`) an einem nested-attributes-Kind wird
    beim Update übersprungen, weil autosave nur geänderte Kinder speichert. Folge: Bearbeitete Split-Regeln wurden
    nie gespeichert (Neuanlage ging). Behoben per `value_will_change!` im Setter, Controller-Test für das Update.
    Prüffrage: Setzt ein Formular ein virtuelles Attribut an einem bestehenden Kind-Datensatz, gibt es einen
    Update-Test (nicht nur Create)?
  - L10 (07.10., PR 3573, CodeRabbit, Commit a979c95): Ein angezeigter Betrag darf keine bekannte Unsicherheit
    enthalten. Ist nur eine Spanne sicher (Tag mit Buchungen nach dem Sync), nur den sicher erklärten Teil zeigen.
  - L18 (07.10., upstream PR 3794, Lektionen-Prüfung, Commit 0ecc773): Rechte enger gemacht (Instanz-Einstellungen nur
    noch für super_admin bei mehreren Familien), aber Altinstallationen ohne super_admin hatten keinen Weg zurück.
    Behoben mit Upgrade-Hinweis samt Befehl in docker.md, Satz in oidc.md und Verweis im Hinweistext der Seite.
    Prüffrage: Sperrt eine neue Rechteprüfung jemanden aus, der vorher durfte, nennt dann die Fehlermeldung oder der
    Hinweis an genau dieser Stelle den Weg zurück (nicht nur die Doku)?
  - L18 (07.10., upstream PR 3794, CodeRabbit, Commit e0c73e8): Der neue Upgrade-Hinweis nannte pauschal „AI settings“ als
    instanzweit, obwohl die Assistenten-Auswahl pro Familie ist. Prüffrage: Beschreibt ein Hinweis Rechte, deckt er sich
    Feld für Feld mit der Prüfung im Code (welche Felder global, welche pro Familie)?
  - L21 (07.10., upstream PR 3843, Lektionen-Prüfung B2, Commit 611337b): Die Race-Logik (find, Savepoint-create,
    rescue name taken, find_by!) war eine Zeile-für-Zeile-Kopie von `FamilyMerchant.find_or_create_with_name` aus dem
    eigenen offenen PR 3824. Behoben, indem 3843 den Helfer byte-gleich mitbringt und aufruft; gleiche Hunks mergen
    in beide Richtungen konfliktfrei (geprüft mit `git merge-tree`), ohne die PRs zu stapeln. Prüffrage geschärft:
    Vor jedem find-or-create, Race-Rescue oder Brandfetch-/URL-Bau auch die eigenen offenen PRs nach einem Helfer
    durchsuchen (`git grep` auf deren Heads), nicht nur main.
- 07.10. upstream PR 4013 (1 Befund behoben, Commit f603d6c, Thread „Befunde PR 4013“):
  - L2/L21 (bekannte Art, durchgerutscht): Der Rake-Task rules:apply_all lief weiter Regel für Regel über
    RuleJob.perform_now, während UI und Job auf einen Rule::Runner-Durchlauf umgestellt waren (O(N²) Abfragen).
    Prüffrage geschärft: Wer einen Kernablauf umbaut, sucht per grep auch in lib/tasks und db/seeds nach den
    alten Einstiegen und stellt sie auf denselben Weg um.
  - L16/L8 (neue Prüffrage): `perform_now` auf einem Job mit `retry_on` wirft den Fehler nicht, sondern plant
    still einen Retry ein; Aufrufer (Rake, Konsole) melden dann Erfolg. In Tasks das Model direkt aufrufen
    oder die Ausnahme selbst behandeln, mit Exit-Code ungleich 0; Test mit belegter Sperre und assert_no_enqueued_jobs.
  - L22 (07.10., upstream PR 3719, Lektionen-Prüfung B4, Commit fdf22e0): Der PR machte nur die Anzeige
    (`categorizable?`, `payment?`) robust gegen ein vom ProviderImportAdapter überschriebenes `kind`, Budgets und
    Berichte lasen weiter das falsche Feld (Kredit-Rückzahlung doppelt als Ausgabe). Behoben an der Ursache: der
    Adapter leitet das `kind` gematchter Beine aus dem Transfer ab (repariert auch Altbestand). Prüffrage geschärft:
    Wenn ein Kommentar „X kann später überschrieben werden“ erklärt, warum die Anzeige X ignoriert, prüfen, wer X
    sonst noch liest, und das Überschreiben selbst abstellen.
  - L21 (07.10., upstream PR 3719, gleicher Commit): Drei Kopien der Transfer-Kind-Regel (Transfer.kind_for_account,
    Transfer::Creator, Family::DataImporter); Creator und DataImporter rufen jetzt die Modellmethode.
- 07.10. upstream PR 3098 (Thread „Befunde PR 3098“, Commits f5eff9a, 7b5fff9, 6e7b9bc):
  - L18 (bekannte Art, durchgerutscht): Drei neue ENV-Defaults (MARKET_DATA_SYNC_*) und ein Cron-Job, der von
    schedule.yml in einen Startup-Hook wanderte, ohne .env.example, Hosting-Doku und Upgrade-Hinweis. Prüffrage
    geschärft: Verschiebt ein PR einen Job aus config/schedule.yml in Code, steht in docs/hosting, wo man ihn nach
    dem Upgrade findet (/sidekiq Cron-Tab, Log-Präfix) und wie man ihn neu anlegt. Bei ENV-Booleans dokumentieren,
    welcher Wert als „an“ zählt (hier nur "1", „true“ schaltet ab).
  - L1 (Altbefund aus befunde-2026-10-07.md): Ein Status wie resolution_pending, der nur gesetzt, aber nie
    zurückgesetzt wird, macht eine Wiederholung dauerhaft. Prüffrage: „Welcher Weg setzt den neuen Status wieder
    zurück, auch wenn der nächste Versuch ‚kein Treffer' statt ‚Erfolg' ergibt?“
  - L11 (Altbefund): de-Texte für die neuen Einstellungen nachgetragen.
- L16 (07.10., upstream PR 3777, Lektionen-Prüfung, Commit f3f025a): Am 100-Seiten-Deckel abgeschnittener Erstabruf
  („longest“ oder langes Startdatum) wurde als Erfolg gemeldet, nur Rails-Log; danach inkrementell, Rest nie geholt.
  Behoben: DebugLogEntry bei jedem Abschneiden, Erstabruf (BOOK, Seitenlimit) als Sync-Fehler mit übersetztem Text,
  Seiten bleiben gespeichert. Neue Prüffrage: Wenn ein Teilergebnis als Fehler gemeldet wird, läuft die
  Weiterverarbeitung (Syncer Phase 3, Saldo-Jobs) trotzdem? Sonst wird aus „teilweise“ ein „gar nichts“ für alle
  Konten des Items (vom Code-Review gefunden, Syncer verarbeitet jetzt erst und meldet dann den Fehler).
- 07.10. Fork #15 (Befund aus der L16-Prüfung, Commits 458b8da + 9d13d6c, Thread „Befunde Fork 15“):
  - L16 (bekannte Art, durchgerutscht): Ein Hintergrundjob meldete Erfolg, obwohl der Upload in den
    Dokumentenspeicher `nil` lieferte; kein Retry, kein DebugLogEntry, die Liste zeigte „durchsuchbar“.
    Prüffrage: „Gibt jede Sync-/Upload-Methode bei einem Fehlschlag etwas zurück, das der Job als Fehler
    behandelt, und loggt der Job nach den letzten Versuchen per DebugLogEntry?“
  - L6/L8 geschärft (eigenes Review): Ein Retry darf keinen Zustand hinterlassen, der für immer „wartet“.
    Prüffrage: „Was zeigt die UI, wenn alle Versuche scheitern oder der Dienst gar nicht eingerichtet ist?
    Gibt es dafür einen Endzustand (Opt-in zurücknehmen, Button ausblenden) statt eines ewigen ‚läuft‘?“
  - Nachtrag 07.10. (bae97dd): Der neue Regel-Systemtest war in der Upstream-CI rot („Rule updated“ fehlte), lokal
    9-mal grün. Gehärtet: auf den gewählten Tag im Trigger warten und das offene Tag-Menü vor dem Speichern
    schließen; danach CI-Systemtests grün. Prüffrage: Öffnet ein Systemtest ein Dropdown/Overlay, schließt er es
    vor dem nächsten Klick auf Knöpfe darunter?
- 07.10. Fork #22 (Befund aus der L18-Prüfung, Commit f8cac7c, Thread „Befunde Fork 22“): L18 (bekannte Art,
  durchgerutscht): `WEBUI_AUTH` von False auf True ohne Hinweis, wie man sich danach anmeldet. Open WebUI hatte im
  Modus ohne Login schon admin@localhost/admin angelegt; neue Konten sind nur „pending“. Behoben: Hinweis in der
  Compose-Datei, Upgrade-Abschnitt in docs/hosting/docker.md, Port 8080 nur noch auf 127.0.0.1. Prüffrage
  geschärft: Schaltet ein PR Auth für einen Drittdienst ein, wie lautet das Konto, das Bestandsinstallationen
  schon haben (im Quellcode des Dienstes nachsehen), und ist der Dienst bis zur Passwortänderung nur lokal erreichbar?
- 07.10. Fork #56 (Befund aus befunde-2026-10-07-neu.md Teil 1, Commit 16b55cc, Thread „Befunde Fork 56“): L18
  (bekannte Art, durchgerutscht): Neuer ENV-Schalter PAPERLESS_ALLOW_PRIVATE_HOSTS, dessen Default je nach
  SELF_HOSTED wechselt, stand nur in einer Fehlermeldung. Behoben: kommentierter Eintrag mit beiden Defaults in
  .env.example, neue docs/hosting/paperless.md mit Default-Tabelle, Test nach dem Muster von openai_test
  („knob is documented“). Prüffrage geschärft: Steht jede ENV-Variable, die der Diff neu liest (`grep ENV\[`),
  in .env.example und docs/hosting, und bei modusabhängigem Default beide Defaults? Eine Fehlermeldung, die eine
  ENV nennt, ist keine Doku.
- 07.10. Fork #80 (Befund aus befunde-2026-10-07-neu.md Teil 1, Commit cb71ab5, Thread „Befunde Fork 80“): L18
  (bekannte Art, durchgerutscht) mit L16: Der Default einer neuen Einstellung (Edelmetall-Referenz Yahoo GC=F usw.)
  setzte einen Anbieter voraus, der auf Standard-Installationen (twelve_data) nicht aktiv ist; der Import lieferte
  dann still 0 Kurse bei „Sync erfolgreich“. Zusätzlich setzte find_or_create_by! den Anbieter nur beim Anlegen.
  Behoben: Warn-DebugLogEntry statt stillem No-op, Warnhinweis je Metall in den Einstellungen, geänderter Anbieter
  wird auf die bestehende Referenz übernommen (Default Yahoo bleibt, Owner-Entscheidung). Prüffrage geschärft:
  Setzt ein neuer Default einen Anbieter, ein Feature oder einen Schlüssel voraus, der nicht standardmäßig aktiv
  ist? Dann muss die UI das sichtbar machen und der Lauf einen DebugLogEntry schreiben. Und: Werte im Block von
  find_or_create_by! gelten nur beim Anlegen; soll die Einstellung später wirken, auch den Fundfall aktualisieren.
  - Nachtrag 07.10. (fac1423, CodeRabbit): `127.0.0.1:`-Portbindung ist erst ab Docker Engine 28.0.0 wirklich nur
    lokal; ältere Engines lassen Hosts im selben L2-Netz durch. Prüffrage L18 ergänzt: Verspricht ein PR „nur lokal
    erreichbar“, nennt er die Mindestversion der Plattform und den Ausweg (Firewall) für ältere.
- 07.10. Fork #54 (Befund aus befunde-2026-10-07-neu.md Teil 1, Commit 260ab91, Thread „Befunde Fork 54“):
  - L6 (bekannte Art, durchgerutscht): Die Speicher-Kette pro Gruppe im Konten-Zieh-Controller nutzte `fetch` ohne
    Timeout; ein hängender Request blockierte alle späteren Speicherungen, der Fehler-Toast kam nie. Jetzt
    `AbortSignal.timeout(saveTimeout)`. Prüffrage geschärft: Wer Requests verkettet (Promise-Kette, Warteschlange),
    braucht pro Request ein Timeout, sonst blockiert einer alle folgenden.
  - L21: Dritte Kopie der Zieh-Logik (Dashboard/Berichte/Konten). Entscheidung: gemeinsame Basis als eigener Fork-PR.
  - Nachtrag 07.10. (Fork 92, 35bcc51): Basis controllers/sortable_base.js umgesetzt, Unterschiede als Schalter. Prüffrage L7 dazu: Systemtests, die
    ein Speichern per fetch prüfen, brauchen im Test-Env ein CSRF-Meta-Tag (Controller brechen ohne ab) und ein Warten auf genau diesen Request.
  - Nachtrag 07.10. (ead2436, CodeRabbit): Als Ausweg „Host-Firewall (UFW)“ empfohlen, aber Docker leitet
    veröffentlichte Ports per NAT an UFW vorbei. Richtig: Docker aktualisieren, sonst DOCKER-USER-Kette. Prüffrage:
    Funktioniert die empfohlene Abhilfe auf der Plattform wirklich (Doku des Herstellers geprüft)?
- 07.10. Fork #85 (Befund aus befunde-2026-10-07-neu.md Teil 1, Commit 28070e0, Thread „Befunde Fork 85“):
  - L20 (bekannte Art, durchgerutscht): Fork #85 und #87 legten beide neu test/controllers/passwords_controller_test.rb
    an (add/add-Konflikt für den zweiten Merge). Behoben ohne Stapeln: Tests von #85 in eigene Themen-Datei
    passwords_sso_only_test.rb. Prüffrage geschärft: Legt ein PR eine neue Datei an, vorher prüfen, ob ein anderer
    offener PR (Fork und eigene Upstream-PRs) dieselbe Datei anlegt (`git merge-tree` gegen die Geschwister-Branches);
    bei mehreren PRs zum selben Controller Testdateien nach Thema benennen.
- 07.10. Fork #87 (Befunde aus befunde-2026-10-07-neu.md Teil 1, Commit 118aa51, Thread „Befunde Fork 87“):
  - L1 (bekannte Art, durchgerutscht, Muster aus 3264): Neue Passwort-Validierung hatte `return if password.blank?`.
    Bei `has_secure_password` wird `""` ignoriert, `update` meldet Erfolg ohne Änderung. Prüffrage geschärft: Wer eine
    Validierung „nur wenn gesetzt“ schreibt, prüft, ob der Weg einen neuen Wert erzwingen muss (Passwort ändern = Pflicht).
  - L11: Fehlertexte nur in 9 von 19 Locales. Prüffrage: Wo dieselbe Regel schon in anderen Locale-Dateien übersetzt ist
    (z. B. views/registrations), müssen neue Keys in genau diesen Locales stehen; i18n-Test über alle Locales.
  - L21: Fünfte Kopie der Passwortregeln. Jetzt eine Quelle (PasswordPolicy), Texte je Weg bleiben.
  - L20: Gleiche neue Testdatei in Fork 85 und 87; der Fork-85-Thread hat seine umbenannt, merge-tree sauber.
- 07.10. (Fork 93, Zieh-Fehler, CodeRabbit):
  - L6 geschärft: Zustand, der erst beim „Loslassen“ gespeichert wird, braucht neben disconnect() auch pagehide
    (volle Seitenladung, Tab schließen) und fetch mit keepalive. Prüffrage: Was passiert mit offenem UI-Zustand bei
    Turbo-Navigation UND bei voller Navigation?
- 07.10. (Fork 94, 72-Byte-Grenze, eigenes /code-review vor dem PR):
  - L21: Byte-Prüfung zuerst doppelt (Policy und Model). Jetzt ein Helfer PasswordPolicy.too_long?.
  - L7: Ein neuer Test („ohne neues Passwort keine Prüfung“) war auch ohne Fix grün; entfernt.
  - L15: Signup lehnt jetzt mehr ab, rswag-Beschreibung und openapi.yaml nachgezogen.
  - L11 geschärft: Wird `count:` an alle Texte einer Schleife gereicht, landet die falsche Zahl in fremden Texten,
    sobald dort %{count} steht. Interpolationswerte nur an den Text geben, zu dem sie gehören.
- 07.10. (Fork 96, Abfragekosten Transfer-Art beim Sync, eigenes /code-review vor dem PR):
  - L14 geschärft: Memoisieren pro Adapter/Objekt nur, wenn klar ist, wie lange das Objekt lebt. Die meisten
    Entry-Processoren bauen je Zeile einen neuen ProviderImportAdapter; ein Konto-weiter Vorrat je Adapter lud so die
    ganze Transfer-Historie pro Zeile. Prüffrage: Wie oft wird das Objekt pro Sync gebaut, und ändert der Sync die
    gecachten Daten selbst (Trade Republic legt Transfers mitten im Sync an und löscht sie)? Lösung: eine
    eager_load-Abfrage je Zeile statt Cache.
  - L7/L22: Bestehende Tests mussten für den Cache umgebaut werden – Warnsignal, dass der Fix ein Verhalten bricht.
    Ein zweiter neuer Test war ohne Fix grün; entfernt.
- 08.10. (Fork-PR-Job, Befunde auf Fork 89, 90, 91, 93):
  - L2 (Fork 89): Der Insight-Generator IdleCashGenerator las `family.accounts.visible` und zeigte so Namen und Saldo
    privater Konten im familienweiten Insight-Feed. Jeder Generator, der in einem familienweiten Feed landet, muss
    `shared_accounts` nutzen; neuer Test mit privatem und geteiltem Konto.
  - L1/L7 (Fork 91): Die Prüfung auf reservierte Client-Namen entfernte nur Unicode-Formatzeichen (\p{Cf}); U+034F
    (Combining Grapheme Joiner, kein Cf) umging sie. Bei Namens-/Blocklistenprüfungen alle unsichtbaren Zeichen
    normalisieren, nicht nur eine Kategorie.
  - L7 (Fork 90, 93): Ein Test war zu schwach. Concurrency-Fixes brauchen einen echten Zwei-Verbindungs-Test (ohne
    transaktionale Tests); ein JS-Unload-Test muss wirklich navigieren und das gespeicherte Ergebnis auf der Zielseite
    prüfen, statt ein Event künstlich auszulösen.
- 08.10. (Merge main in Fork 59, Thread „Konflikt Fork #59 Transfer-Art“):
  - L2/L13: Beim Merge von main nicht nur die Textkonflikte lösen. main hatte eine neue Pflicht für alle Einträge in
    config/schedule.yml eingeführt (`active_job: true`, CronScheduleTest); unser Eintrag mergte konfliktfrei und
    brach den Test. Prüffrage nach jedem main-Merge: Welche neuen Invarianten/Tests bringt main, und erfüllen
    unsere neuen Einträge (Jobs, Kinds, Routen) sie? Volle Testsuite vor dem Push.
  - L10: Neue Aufrufer aus main (kind_for_leg, categorizable?) mussten die zusätzlichen Parameter (Buchungsdatum)
    bekommen, sonst rechnen sie anders als Creator/Import und laden je Zeile die Familie nach.
- 08.10. (Issue 4037 Punkte 1–3, Thread „Issue 4037“):
  - L10: Fix für verknüpfte Einzahlungen im Investment-Bericht übersah das Spiegelbild (verknüpfte Auszahlungen
    fallen genauso heraus). Prüffrage bei jedem Richtungs-Fix (Zufluss/Abfluss, Einzahlung/Auszahlung, Soll/Haben):
    Gilt derselbe Fehler für die Gegenrichtung? Test für beide Richtungen.
  - L3: Eine neue Read-only-Anzeige (Kategorie des Abgangs-Beins auf dem Zugangs-Bein) zeigte Daten eines Kontos,
    das der Betrachter nicht sehen darf. Wer Daten des Gegenbeins anzeigt, nutzt dieselbe Schwärzung wie der
    Gegenkonto-Name (@accessible_account_ids) und testet mit einem nicht freigegebenen Konto.
  - L12: `title` am Wrapper wird vom title des DS::Pill überdeckt und ist für Tastatur/Touch unsichtbar; Hinweise
    über DS::Tooltip.
- 08.10. (Fork #98, Upstream-Kopie des Insights-Freigabe-Fixes, Thread „Saldo-Warnung nach Freigabe-Entzug“):
  - L7: Ein Test für einen Sonderweg (hier: Ablauf einer per Lese-Filter versteckten Zeile) prüft die
    Vorbedingung ausdrücklich (`assert_not ...visible.exists?`), sonst kann er über den normalen Weg grün werden.
- 08.10. (upstream PR 4064, Nacharbeiten Issue 4037, CodeRabbit):
  - L2: Eine Sperre (Kategorie nur am Abgang) hing am änderbaren `kind` des Beins; ein auf „standard“
    umgestelltes Zugangs-Bein umging sie über beide Schreibwege. Sperren an den stabilen Datensatz (Transfer)
    hängen, nicht an ein Feld, das der Nutzer über denselben Controller ändern kann; Test mit geändertem Feld.
  - L18: `ENV["X"].present?` macht aus `X=0`/`X=false` ein Ja. Schalter per
    `ActiveModel::Type::Boolean.new.cast(ENV["X"]) || false` lesen.
- 08.10. (Review upstream PRs 4044/4046/4048, Owner-Entscheidung Application ID):
  - L3/L24: Nicht nur Schlüssel und Tokens, auch Identifikatoren, die Teil eines Credentials sind (Enable
    Banking `application_id` = JWT-`kid`), nie ins Formular vorbefüllen; „leer = behalten“-Regel wie beim
    Zertifikat, Key in `filter_parameters`, möglichst `encrypts`. Prüffrage: Welche Felder im Admin-Formular
    sind Teil eines Credentials, und welche davon kommen mit Wert zurück?
  - L2/L24 (Bug, den upstream PR 4048 behebt): Eine Sammlung (Provider-Karte) wurde zugelassen, sobald EIN
    Element sichtbar ist (`(ids & accessible_ids).any?`), dann aber komplett gerendert. Prüffrage: Wenn ein
    Container wegen eines sichtbaren Elements angezeigt wird, filtert die Anzeige dann auch seine übrigen
    Elemente, Summen, Namen und Detaillisten? Test mit „eins geteilt, eins nicht“ und Name des nicht geteilten
    Elements darf nicht im HTML stehen.
  - L24/L8 (Bug, den upstream PR 4046 nebenbei behebt): Ein Partial, das auch per Broadcast gerendert wird,
    las `Current.user.accessible_accounts`; ohne Betrachter ist `Current.user` nil, der Render warf, und
    `Sync#perform_post_sync` loggte nur, sodass der Sync-Hinweis bei Trading 212 nie ankam. Prüffrage: Läuft
    jedes per Broadcast gerenderte Partial mit `Current.user = nil`? Test: Partial per
    `ApplicationController.render` ohne Betrachter rendern.
- 10.10. (upstream PR 3833, Schwärzung von DebugLogEntry-Metadaten, eigenes Security-Review):
  - L3: Wer eine Schwärzung lockert (hier: Geld-Container durchlaufen statt ganz ersetzen), prüft drei Wege:
    (1) Ausnahmen nach Namensmuster („*_currency“) treffen auch Schlüssel mit Betrag
    (`amount_in_account_currency`), also nur exakte Namen und nur im Container freigeben; (2) Hash-Schlüssel
    selbst können Identifikatoren sein (IBAN, Adresse als Key), solche Hashes ganz schwärzen; (3) bei
    Schlüsseln, die zugleich Geld- und Identifikator-Muster treffen (`address_balances`), gewinnt immer der
    Identifikator. Test je Weg mit Klartext-Wert, der nicht im Ergebnis stehen darf.
- 10.10. (upstream PR 3510, Merge mit upstream PR 3824, eigenes Code-Review):
  - L2: Ein „find_or_create“-Helfer, der jedes `RecordNotUnique` als „Name schon da“ deutet, verschluckt
    Verletzungen anderer Unique-Indizes (hier family_id + iban) und macht aus „IBAN vergeben“ ein 404
    (`find_by!` findet nichts). Prüffrage: Hat die Tabelle mehr als einen Unique-Index? Dann im Rescue prüfen,
    ob wirklich der gesuchte Datensatz existiert, sonst die Original-Exception weiterwerfen.
  - L2: Wird ein Feld beim Umwandeln/Kopieren still geerbt (IBAN vom geteilten Händler), kann eine Änderung an
    einem ganz anderen Feld (nur Website) an dessen Eindeutigkeit scheitern, die der Nutzer nie angefasst hat.
    Geerbte Werte mit Unique-Regel vorher gegen den Ziel-Mandanten prüfen und im Konfliktfall weglassen; Test
    „nur Website ändern, IBAN gehört schon einem anderen Händler“.
- 10.10. (PR 4005, behoben in 278a152): Ablauf-Lektion: CodeRabbit-„Nitpick comments“ stehen oft nur im
  Review-Body, ohne Inline-Thread. Sie sind Befunde wie Threads (umsetzen, kurzer PR-Kommentar, danach
  „@coderabbitai review“, weil CodeRabbit nach mehreren Commits pausiert). Test-Lektion: Ein Gast-/Rechte-Test
  muss dasselbe Format wie die Nachbartests nutzen (Turbo Stream statt HTML) und ein Setup, in dem der
  Nicht-Gast die Wirkung sieht; sonst ist er auch ohne die Prüfung grün. Je geänderter Zweig ein Test.

- 12.10.2026, upstream PR 4013 (Codex-Review, 4× P2), Fork-Branch feat/rule-order-stop-processing, Commit 36cf5e8:
  - L22/L10 (neue Prüffrage): Mehrere Aktionen auf einer ActiveRecord-Relation werten die WHERE-Bedingungen bei jeder Aktion neu aus. Ändert eine Aktion ein Feld, auf das die Bedingung filtert (Umbenennen), sieht die nächste Aktion andere Datensätze als die einmal geplückten IDs, mit denen Buchführung (Claims) arbeitet. Prüffrage: Arbeiten alle Schritte und die Buchführung auf derselben, einmal festgelegten ID-Menge?
  - L8: Code im `ensure` läuft außerhalb des `rescue`. Kann er selbst werfen (hier ungültiger action_type aus Import), bricht er die ganze Schleife ab. Prüffrage: Was in `ensure` steht, darf nicht werfen oder braucht eigenes Rescue; Test „kaputter Datensatz gefolgt von gesundem“.
  - L13: Kommentar und PR-Text versprachen „Einzelregel = wie im vollen Lauf“, der Code simulierte Änderungen der Regeln darüber aber nicht. Zusagen in Kommentaren/PR-Text auf das beschränken, was ein Test belegt.
  - L12: Handgebauter Icon-Button (Reorder-Griff) statt DS::Button variant: :icon.
  - Nachtrag 12.10. abends (Owner-Entscheidung zu P2-2, Commit 6e784ef): Statt die Zusage abzuschwächen, führt „Regel anwenden“ jetzt die aktiven Regeln darüber vorher aus. Lehre (L13/L19): Wenn ein Review „simulieren oder Vertrag abschwächen“ anbietet, die dritte Option prüfen (Vorgänger wirklich ausführen) und dem Owner vorlegen, bevor man abschwächt.

- 13.10.2026, upstream PR 3020 (eigenes /code-review vor dem Push, Split-API um Händler/Tags erweitert), Fork-Branch feat/split-transaction-rule-action, Commit dc711c0:
  - L2 (Wege-Tabelle): Neues Feld im Modell (Händler/Tags pro Split-Teil) erreichte Web-Dialog, Regel und Import, aber nicht den inzwischen in main gelandeten API-Weg. Weil PATCH alle Teile ersetzt, löschte eine API-Rundreise die neuen Felder still. Prüffrage nach jedem Merge von main: Ist ein neuer Weg (API-Endpunkt) dazugekommen, der die neuen Felder noch nicht kennt?
  - L1/L8: Strong Params verwerfen nicht-skalare IDs (Array/Hash) still; die API muss sie vorher mit 422 ablehnen, sonst wird der Datensatz ohne das Feld gespeichert.
  - L21: Merchant-Scope (available_merchants_for) stand in zwei Controllern; jetzt Entry::SplitReferences.for_user.
  - L13: Doku „nullable, Standard = Händler der Hauptbuchung“ verschwieg, dass null wie Weglassen wirkt; Doku präzisiert.
- 13.10.2026 Wochenauswertung (erster Lauf Review-Lern-Job; Liste befunde-woche-2026-10-13.md):
  Fork 06.–13.10.: 36 CodeRabbit-Befunde in 23 PRs (27 bekannt, 7 durchgerutscht, 2 neu). Bugfix-Rückblick
  13.04.–13.10. auf Upstream-main: 465 Code-Fixes per blame ihrem Verursacher zugeordnet, 146 genau geprüft
  (58 bekannt, 78 durchgerutscht, 10 neu). Neue Lektionen L26–L31 (oben). Upstream 06.–13.10.: 38 Befunde in 16 eigenen PRs (29 bekannt, 9 durchgerutscht), 15 PRs gemergt.
  Eigene Verursacher-PRs: 2968 (Fixes 3460, 3462), 3397 (3444), 3058 (3907), 3719 (4064).
  Geschärfte Prüffragen:
  - L16 (25 durchgerutscht, größte Lücke): (a) Snapshot-Abgleich: Was passiert mit Positionen/Konten, die der
    Provider nicht mehr liefert, und wird eine leere Antwort von einem Ausfall unterschieden (3234, 3484)?
    (b) Einheit je Feld festlegen (Gesamt vs. pro Stück, Kontrakt-Multiplikator, netto nach Gebühr) und
    Gegenprobe: Summe der importierten Trades = vom Anbieter gemeldeter Bestand/Saldo (1692, 3744, 4086, 4038).
    (c) Jedes stille return/next und jeder unbekannte Typ/Code bekommt DebugLogEntry mit Zählung oder einen
    Fallback (2212, 3653, 4105, 3090). (d) Auth, Fehlerformen und Felder gegen echte Doku/Sandbox und Payloads
    mehrerer Banken prüfen, nicht nur gegen eigene Mocks (1888, 2968, 3112). (e) Ein Schalter wirkt auf Abruf
    UND Neuverarbeitung gespeicherter Payloads (2835); Ausweichen auf einen schwächeren Endpunkt oder ein
    abgelehnter optionaler Parameter wird als Teilergebnis gemeldet, nicht still (3391, 1789). (f) Jeder
    Bulk-Weg (update_all bei Merge/Convert/Unlink) setzt user_modified (1981). (g) Namens-/unscharfe Zuordnung
    nur eindeutig und nie auf eine lebende, schon verknüpfte Entität (3116). (h) Erster Durchlauf ohne
    Credentials und Erst-Sync über Provider-Limits hinaus durchspielen (1613, 2998). (i) Mehrere Listings
    pro Symbol: das preisbare wählen; zeitabhängige Faktoren auch historisch (2413). (j) Neuer Schritt im
    Sync: steht ein früher `return unless …` davor, der für ihn nicht gilt (Fork 80)?
  - L6 (13): Mobilbreite 320 px mit langen Namen, Dialog-Dropdowns je Breakpoint, Icons shrink-0 (1693, 2148,
    2962, 3729); Browser zurück/vor mit Turbo-Cache (3886); Safari/WebKit (3365); Broadcast/Refresh darf offene
    Formulare anderer nicht zerstören (1964, 2105); Stimulus-Zustand im DOM statt Instanzvariable wegen Morph
    (2812); verschachtelte Formulare/button_to (3940); im Browser erzeugte Nested-Attribute-Keys rein numerisch,
    Systemtest durch den echten Submit (3444, eigener PR 3397); fetch beim Seitenwechsel mit keepalive (Fork 93);
    eingeschränkte Auswahlliste zeigt gespeicherten Altwert weiter (Fork 66).
  - L1 (14): Options-Hash-Keys Symbol/String normalisieren (3916); nichts aus gerundeten Größen zurückrechnen
    (4111); Duplikat fachlich definieren, nicht über size > 1 (2569); Formular-Default = Modell-Ableitung
    (3070); Preflight-Pflichtfelder = NOT-NULL-Spalten (2775); mehrere „NULL = alles“-Einträge dürfen nicht
    über 100 % summieren, bei jeder Zustandsänderung prüfen (3160); Präfixe wie „Apple Pay:“ vor dem
    Händler-Match abschneiden (3460, eigener PR 2968); Monatsgrenzen mit travel_to (2880); Current.family
    kann in Layout/Fehlerseiten nil sein (2006); Parser-Test je Formatfamilie (2500); Fallback-Werte auch im
    JS-Konsumenten (4032); beim Kopieren/Splitten neue Felder mitnehmen (Fork 74).
  - L12 (5): Jeder Zustand in Hell und Dunkel angesehen, Kontrast AA; jede Utility/jedes Token existiert
    wirklich; bei DS-Änderung alle Aufrufer per grep prüfen (1464, 1929, 2139, 2287, 3521).
  - L10 (4): Invariante start + Flows = end in jedem Sonderfall-Zweig (2031); Zeitraumvergleiche mit gleich
    vielen verstrichenen Tagen (3457); Chart, Trend und Text mit derselben Rundung (3091); API-Scope = Web-Scope (1723).
  - L2 (4): Bulk-Aktionen über alle Entryable-Typen (1877); jeder Weg, der eine Familie anlegt, macht den
    Ersteller zum Admin (3024); Normalisierung auch auf update_columns-/validate:false-Wegen (2299);
    neue Matcher für alle Serientypen (3932).
  - L3 (3): Neue Betragsfelder im Privacy-Modus (3801); Backfill-Roundtrip je Spaltentyp inkl. json/leer
    (2615); ohne konfigurierte Verschlüsselung Klartext verweigern statt still speichern (3415).
  - L4: Uniqueness-Validierung wirft RecordInvalid (:taken) vor dem INSERT, beide abfangen (Fork 33);
    Elternobjekt kann zwischen Laden und Schreiben gelöscht werden, InvalidForeignKey sauber behandeln (2896).
  - L5: db/schema.rb-Version = höchste Migration im Branch, nach jedem Merge neu dumpen (Fork 100).
  - L7: Ende-zu-Ende-Test des ganzen Flows, nicht nur Einzelteile (2884); Generatoren einmal real ausführen (3047).
  - L8: Kann ein Programmierfehler (NameError) im rescue verschwinden, während der Sync Erfolg meldet (2702)?
    Ein fehlender Einzelwert bricht nicht das ganze Konto ab (3493); kein wiederkehrendes Log-Rauschen (2776).
  - L9: Nur IDs/Primitive cachen, keine ActiveRecord-Objekte (3907, eigener PR 3058).
  - L11: Lokalisierte Zahlen/Prozente in festen Spaltenbreiten mit mehreren Locales prüfen (2275).
  - L13: Kurz vor dem Merge auf aktuellen main bringen und volle Suite laufen lassen (3584).
  - L14: Provider-Calls nur für noch gebrauchte Datensätze (3888).
  - L18: OpenAI-kompatible Endpunkte ohne /models (3184); unbegrenzte ID-Listen in URLs sprengen Proxy-Limits (3018).
- 13.10.2026, upstream PR 3020 (CodeRabbit-Review 5499220665, 2 Befunde, behoben in 3a37fe8):
  - L2/L22: Eine gemeinsame Sperr-Methode (Entry#split_once!) wurde für Regel und API eingeführt, aber der dritte Weg (manueller Split-Dialog) blieb ohne Sperre. Prüffrage: Wenn eine Absicherung „für alle Wege“ zentralisiert wird, die Wege-Tabelle durchgehen und jeden Aufrufer der alten, ungesperrten Methode umstellen.
  - L22 (Ursache): Re-Check unter der Sperre prüfte nur Eigenschaften der gesperrten Zeile (entries), nicht die der zugehörigen Zeile (transactions: pending, Transfer), die ein Sync parallel ändern kann. Prüffrage: Liest die Bedingung unter dem Lock Spalten aus einer Tabelle, die nicht gesperrt ist?
  - Upstream (eigene PRs, 06.–13.10.), zusätzlich geschärft:
    - L4: Unter dem Lock ALLE Vorbedingungen neu prüfen, nicht nur einen Teil (3020: pending/Transfer fehlten);
      Zustandsübergänge idempotent, Test „Aktion zweimal aufrufen ändert beim zweiten Mal nichts“ (3034 confirm!).
    - L2: Für eingeschränkte Rollen jedes erlaubte Feld auf Seiteneffekte prüfen (user_modified sperrt Syncs, 4000).
    - L8: Rechtefehler je Format antworten: HTML Redirect, Turbo Stream/JSON 403 (4005).
    - L10: Auswahl und Ausführung auf derselben Treffermenge, nicht zweimal abfragen (4013, Codex-P2 nach Merge).
    - L11: Pluralformen je Locale vollständig (pl/cs/ru: one/few/many/other), Test mit 2, 5 und 12 (3034).
    - L6: Formularzeilen in der Standard-Dialogbreite mit langen Namen prüfen; lieber zwei Zeilen als drei
      schmale Spalten (3020, gariasf).
    - L19: Neue Features vorher im Discord-Kanal für aktive Beitragende abstimmen (Maintainer, 4013).
    - L20: Nutzer-sichtbare Verhaltensänderungen bekommen einen Release-Notes-Satz in der PR-Beschreibung (4064).
- 13.10.2026, eigenes Lektionen-Review der IBAN-Kette (upstream PRs 3510, 3511, 3512, 3515, 3516, 3518; alle behoben, Details pr-drafts/iban-3511/review-2026-10-13.md):
  - L3/L18: `encrypts` auf eine bestehende Klartext-Spalte wirft beim Lesen alter Zeilen, sobald Schlüssel gesetzt sind (3510, EnableBankingAccount#iban). Prüffrage: Hat die Spalte auf main schon Daten? Dann `support_unencrypted_data: true` pro Spalte plus Backfill-Eintrag und Test mit Klartext-Altzeile.
  - L3: Neue sensible Parameter in filter_parameter_logging (3510); neue verschlüsselte Spalten in security_backfill.rake (3511).
  - L2/L3 (neu geschärft): Ein Sync darf nie familienübergreifende Objekte (ProviderMerchant) mit Daten einer Familie anreichern; eine andere Familie erbt sie sonst beim Umwandeln (3515).
  - L22: Ist ein Bezeichner wirklich eindeutig? Ein Gemeinschaftskonto hat mehrere Zahler mit derselben IBAN; exakter Namensabgleich zuerst, IBAN nur familienweit als Rückfall (3515).
  - L1: Eine spätere Lieferung, die nur ein Teilfeld trägt, darf das andere nicht löschen (3511, IBAN vs. Kontonummer); neue Felder auch beim manuellen Zusammenführen und bei Split-Kindern mitnehmen (3511).
  - L1/L8: Import bricht nicht wegen einer einzelnen kollidierenden Eindeutigkeit ab; Wert verwerfen und als übersprungen zählen (3510).
  - L29: Aufräumlogik nur in einer überschriebenen destroy!-Methode greift nicht bei `dependent: :destroy`; in einen Callback legen und jeden Löschweg testen (3518).
  - L2: Seit 3762 bleibt die Art ausstehender Überweisungen „standard“; `transfer?` allein sagt nicht mehr, ob eine Buchung schon verknüpft ist (Regel „als Überweisung markieren“, Vorschläge; 3518).
  - L3/L2: Automatisch erzeugte Texte dürfen keine Namen von Konten enthalten, die nicht alle Leser des Zielkontos sehen dürfen (3518).
  - L13 (Struktur): Gestapelte PRs, deren Basis-Branch eingefroren ist, bekommen spätere Korrekturen des Basis-PRs nicht; vor jedem Review per merge-tree prüfen, ob ein Folge-PR eine Korrektur still rückgängig macht (3511).
  - L11: Neue Texte in jede Locale, die den Nachbarschlüssel hat (in allen sechs PRs fehlend).
  - L2: Sammel-Update (Bulk) muss Kategorie-, Händler- und Tag-IDs wie die Einzel-Pfade über die Familie auflösen (Fork #37, 13.10.).
  - L1/L8: Nicht lesbare Beträge nicht stillschweigend als 0 werten, sondern enthalten (nil); sonst bestätigt ein Abgleich einen falschen Kandidaten (Fork #44, 13.10.).
  - L1: Ganzzahl-Parsing aus Formularen mit Basis 10 (`Integer(s, 10, exception: false)`), sonst wird „010“ als Oktal gelesen (Fork #59, 13.10.).
  - L7: Neu angelegte abgeleitete Datensätze in anderer Währung müssen alte Zeilen ablösen, sonst zwei Werte pro Datum (Fork #80, 13.10.).
  - L31: Beim Einfügen von Methoden zwischen Doc-Kommentar und `def` verrutscht die Doku (Fork #41, 13.10.).
  - L7: Test-Helfer, die `fetch` umwickeln, dürfen den Body-Typ nicht annehmen (FormData, Blob) (Fork #92, 13.10.).
- 13.10.2026, Fork #102 (Kurs in Fremdwährung umrechnen), Befunde aus /code-review, vor dem PR behoben:
  - L1/L22 (geschärft): `Money#-`/`Money#+` prüfen die Währung nicht, sie nehmen den Betrag des rechten Operanden ungeprüft. Prüffrage: Stammen bei jeder Rechnung mit zwei Money-Werten (Trend, Differenz, Summe) beide aus derselben Währung? Kurse (`Security#current_price`) sind in Börsenwährung, Trades und Holdings nicht unbedingt.
  - L10/L31: Einen Kurs zum Datum des Kurses umrechnen, nicht zu heute. Sonst passt der angezeigte Kurs nicht zu Wert und Kosten, die PortfolioCache zum Kursdatum umrechnet.
  - L8: Kann ein Wert nicht umgerechnet werden, nicht still die Information verlieren: den Originalwert unter seiner Währung zeigen, ihn aber aus Vergleichen und Prüfungen in anderer Währung heraushalten (Konvertieren-Auswahl).
  - L6: Ein neues Partial für mehrere Aufrufer muss nil selbst abfangen und darf sich nicht auf die Prüfung jedes Aufrufers verlassen.
- 13.10. Fork #104 (Lektionen-Prüfung vor Push, Commit d9e6d273d, Thread „Suchfeld am Handy im Dunkelmodus“):
  - L12 (bekannte Art, beim Bauen durchgerutscht): Der Fix für das helle Combobox-Fenster am Handy deckte nur den
    Leerzustand ab; der markierte Treffer blieb im Dunkelmodus hellgrau mit weißer Schrift (Gem-Variable
    --hw-active-bg-color), dazu eine weiße Linie (--hw-option-bg-color). Prüffrage geschärft: Bei Farb-/Theme-Fixes
    an Fremd-Bausteinen (Gems, JS-Libs) alle Zustände mit echten Daten ansehen (leer, mit Treffern, markiert,
    Hover, Fehler) und alle festen Farbvariablen des Bausteins per grep auflisten, nicht nur die sichtbar kaputte.
- 13.10. Fork #105 (Verkauf nur aus eigenen Beständen), Befunde aus /code-review, vor dem PR behoben:
  - L2: Eine neue Prüfung (Verkaufslimit) muss an jedem Schreibweg hängen; die Sammelbearbeitung (Datum verschieben) war zuerst vergessen. Prüffrage: grep nach allen `update`/`save`-Stellen des Modells, auch Bulk-Wege.
  - L28: Eine Regel für „Sell“ lässt sich über andere Labels (Transfer, Sweep Out) umgehen. Am Vorzeichen bzw. der Wirkung prüfen, nicht am Label.
  - L4: Prüfen-dann-Speichern unter Sperre (Konto-Zeile), sonst zählen zwei gleichzeitige Verkäufe dieselben Stücke.
  - L14: Bestandsrechnung pro Tag nicht neu starten; einmal rechnen (auf das eine Wertpapier begrenzt) und memoisieren.
  - L6: Nach 422 müssen alle Formularwerte (Datum, Auswahl, Menge, Preis, Gebühr) im neu gerenderten Formular stehen.
- 14.10. upstream PR 4185 / Fork #105 (Verkauf nur aus eigenen Beständen), Befunde nach dem PR:
  - L1 (CodeRabbit): Termingeschäfte (Trades mit Datum nach heute) und ein angekündigter Split in der Zukunft: Mengen in unterschiedlichen Einheiten addiert. Bei einem Reverse-Split ging ein Verkauf durch, der später ins Minus führt. Prüffrage: Werden Mengen über einen Split-Stichtag hinweg addiert, jede auf die Einheit eines gemeinsamen Stichtags umrechnen, auch für Splits nach heute.
  - L13 (Nachtreview): nb.yml hatte auf main CRLF, die Bearbeitung schrieb LF, dadurch Diff über die ganze Datei. Prüffrage vor dem Push: `git diff --stat origin/main` je Locale-Datei mit der Zahl neuer Schlüssel vergleichen.
- 13.10. upstream PR 4184 (Einstandspreis-Dialog, Fork #103, Fix-Commit 1dc6438), Befunde von CodeRabbit und Codex:
  - L1 (bekannte Art, durchgerutscht; CodeRabbit + Codex P1): Beim Umstieg von handgebautem Feld auf `money_field`
    ging die feste 2-Stellen-Formatierung (`%.2f`) verloren. `money_field` rundet ohne `precision:` auf die
    Nachkommastellen der Währung, bei JPY also 0. Folge: 2 × 12,20 zeigte 24, und „Speichern“ ohne Änderung schrieb
    12,00 je Stück zurück, also eine stille Datenänderung. Beim Bauen war mir die JPY-Rundung aufgefallen, ich hielt
    sie aber für harmlos, weil ich nur an die Anzeige dachte, nicht an den Rückweg beim Speichern. Prüffrage geschärft:
    Wird ein Eingabefeld auf einen gemeinsamen Baustein umgestellt, die Formatierung des vorbelegten Werts (Präzision,
    Rundung, Locale) mit dem alten Feld vergleichen, mit einer Null-Nachkomma-Währung (JPY) testen und fragen:
    „Speichert unverändertes Absenden denselben Wert?“
  - L6 (bekannte Art; Codex P2): `aria-hidden` auf „×“ und „=“ versteckt Zeichen, die hier Bedeutung tragen (Formel
    zwischen den Feldern). Screenreader lasen nur „Pro Anteil, 10 Anteile, Gesamt“. Prüffrage: `aria-hidden` nur für
    rein dekorative Zeichen; Operatoren, Einheiten und Vorzeichen bleiben lesbar.
- 13.10.2026, Fork #106 (Money-Währungsschutz), Befunde aus /code-review und CodeRabbit, behoben:
  - L7: Ein Test, der „kein Fehler“ prüft, ist wertlos, wenn der Code darunter breit `rescue => e` macht (Insight-Registry, Account-Syncer). Dann im Melde-Modus prüfen (`capture_error_reports`), nicht auf Exceptions warten.
  - L7: Kontrolltest („der Test sieht den Fehler wirklich“) nicht an eine Stelle hängen, die gerade woanders repariert wird; sonst wird er nach dem Fix rot. Den Fehler direkt auslösen.
  - L7: Seiten-Smoke-Tests nicht 302 als Erfolg werten; eine Umleitung rendert die geprüfte Logik nie.
  - L22: Bei Prüfungen in Hot Paths (Operatoren, Sortierung) Meldungen je Aufrufstelle entdoppeln, sonst flutet ein Sync das Log.
- 13.10. (Upstream-Vorbereitung AI-Compose, Fork #107, Nachfolger von Fork #22): L18 (bekannte Art, durchgerutscht):
  Der feste WEBUI_SECRET_KEY wurde durch einen generierten ersetzt, ohne Upgrade-Hinweis. Folge für Bestandsinstallationen:
  Open-WebUI-Anmeldungen enden, mit dem alten Schlüssel verschlüsselte Daten (OAuth-Sitzungen/-Verbindungen) sind unlesbar.
  Behoben per Hinweis in docker.md und Compose-Kommentar. Prüffrage geschärft: Wird ein Schlüssel eines Drittdienstes
  (nicht nur SECRET_KEY_BASE) geändert, in dessen Quelle nachsehen, was er alles ableitet bzw. verschlüsselt.
- 13.10. (Upstream-Vorbereitung Versuchslimit Passwortänderung, Nachfolger von Fork #84): L3 (bekannte Art, durchgerutscht):
  Die Drossel war je Session-Cookie geschlüsselt; mehrere Sitzungen desselben Nutzers hatten je eigenes Budget. Jetzt
  je Nutzer (Session-ID → user_id per `Session.where(id:).pick(:user_id)`, nur für PATCH/PUT /password). Prüffrage
  geschärft: gilt auch für Rack::Attack-Drosseln hinter Login, nicht nur für Rails `rate_limit`; Test mit zwei
  `open_session` desselben Nutzers, die zusammen das Limit reißen.

- 13.10. (Fork PR 109, Upstream-Kopie „Gemeinsame Insights ohne private Konten“, Pre-PR-Review):
  - L2/L22: Wird ein familienweiter Generator auf geteilte Konten eingeschränkt, kann die Menge leer sein. Ein
    Budget-Insight meldete dann „im Plan, 0 ausgegeben“, obwohl die Mitglieder privat ausgeben. Prüffrage: Was
    sagt jedes Insight, wenn der Rechte-Scope leer ist oder nur einen Teil zählt? Positive Meldungen („im Plan“)
    bei leerem Scope unterdrücken, je ein Test.
- 13.10. Fork 111 (Index entries/exchange_rates, vor dem PR behoben): L5 geschärft: Wird ein Index durch einen
  neuen ersetzt (add + remove in getrennten Migrationen), den alten nur droppen, wenn der neue per
  `indisvalid` gültig ist; sonst abbrechen. Gültigkeit über `to_regclass(name)` prüfen statt `pg_class.relname`
  (sonst zählt ein gleichnamiger Index in einem anderen Schema). Neu datierte Migrationen: up mit
  valid_index_exists?-Guard, damit Instanzen mit den alten Zeitstempeln nicht scheitern.
- 13.10. (Upstream-Neuaufbau Fork 88 → Fork 112, Pre-PR-/code-review): L2 durchgerutscht: Wege-Tabelle nannte den
  Einstellungs-Weg (PasswordsController) nur mit Modelltest, kein Controller-Test; ergänzt. L7 bestätigt: ein
  Negativtest „falsches aktuelles Passwort“ auf main wäre rot, weil `has_secure_password validations: false` die
  password_challenge-Prüfung abschaltet (behoben im Passwortregel-PR); solche Tests erst nach dessen Merge aufnehmen.
- 13.10.2026 (L7, Fork 113, IDs im Buchungsformular, Review vor Upstream): Rechte-Fix testete nur den Owner-Weg. Ergänzt: Test für das Annotieren-Recht (read_write, eigener slice-Zweig in permitted_entry_params) und Positivtest, dass ein Anbieter-Händler aus dem Picker weiter speicherbar ist. Prüffrage geschärft: Bei Rechte-Fixes je Rollenzweig (owner/full_control/read_write) einen Test und einen Positivtest für den erlaubten Sonderfall.
- 13.10. (Fork 114, Upstream-Fassung von Fork 45, Commit auf claude/project-thread-nhlazm):
  - L13/L20 (bekannte Art): Ein zwei Wochen alter Fork-PR war auf dem neuen main rot, weil upstream PR 4046
    inzwischen 29 Tests ergänzt hatte, die genau das alte Verhalten (Toast direkt beim Sync-Ende) festschreiben.
    Prüffrage geschärft: Vor dem Upstream-Bringen alter Fork-PRs immer die volle Suite auf aktuellem main laufen
    lassen, nicht nur die eigenen Tests; Tests anderer PRs anpassen statt abschwächen (hier: Job im Capture ausführen).
  - L4/L9 (neue Prüffrage): Debounce per Cache-Zeitstempel: Lebt der Cache-Eintrag länger als die längste
    Job-/Recheck-Kette? Sonst hält sich ein verspäteter älterer Lauf für den neuesten (Code-Review-Befund, behoben).
- 13.10. Upstream-Fassung von Fork #91 (Fork #115, Thread „OAuth-Client-Namen und https-Redirects“, 2 Befunde aus Lektionen-Review und /code-review behoben):
  - L1 (bekannte Art, wieder durchgerutscht): Nach dem U+034F-Nachtrag wurde nur dieses eine Zeichen ergänzt; Variation Selectors
    (U+FE0F), Hangul-Füller (U+3164) und nicht komponierbare Kombinationszeichen (U+0332) umgingen die Namenssperre weiter.
    Prüffrage geschärft: Bei Namens-/Blocklisten nach NFKC immer `[\p{Cf}\p{Mn}\p{Me}\p{Default_Ignorable_Code_Point}]` entfernen,
    nicht einzelne Codepunkte nachtragen; Test mit je einem Zeichen pro Klasse.
  - L21: Loopback-Hostliste stand doppelt (Initializer und Controller); auf eine Konstante zusammengeführt.
- 13.10. Fork 116 (Passwortregeln upstream, Commit 6b9da9074, Pre-PR-/code-review): L7/L11 durchgerutscht. Der Test
  „sign-up names each broken password rule in the user's language“ rief nur generate_message unter de auf und prüfte
  dann die englische Seite; ohne de-Übersetzung blieb er grün. Prüffrage geschärft: Ein Sprach-Test rendert die echte
  Seite in der Sprache (Accept-Language oder locale-Param) und prüft den übersetzten Text per assert_select; einmal ohne
  die Übersetzung laufen lassen, er muss rot sein.
- 13.10. Upstream-Fassung von Fork #19 (Fork #117, Thread „SimpleFIN-SSRF-Schutz“, 7 Befunde aus /code-review behoben):
  - L16 (neue Prüffrage): Einmal-Token (Claim, OAuth-Code): Läuft nach dem verbrauchenden Request noch eine Prüfung,
    die vorübergehend scheitern kann (DNS, Netz)? Dann geht der Token verloren. Nach dem Verbrauch nur lokale Prüfungen,
    die volle Prüfung vor dem nächsten Request.
  - L8 (bekannte Art): Eine neue Vorprüfung außerhalb von with_retries machte DNS-Fehler nicht mehr wiederholbar, und der
    neue Fehlertyp :invalid_url wurde im Importer nicht behandelt (kein requires_update, kein DebugLogEntry).
    Prüffrage geschärft: Jeder neue error_type braucht einen Abnehmer bei allen Aufrufern; Vorprüfungen gehören in den Retry-Block.
  - L3/L22 (bekannte Art): SSRF-Guard prüfte DNS getrennt vom Verbindungsaufbau (DNS-Rebinding) und ließ IPv6-Formen mit
    eingebetteter IPv4 (NAT64, 6to4, IPv4-kompatibel), Multicast und reservierte Bereiche durch. Prüffrage geschärft:
    Verbindung auf die geprüfte Adresse pinnen (Net::HTTP#ipaddr), eingebettete IPv4 auspacken.
  - L7: Ablehnungstests prüften nur „irgendein Fehler“; jetzt immer error_type prüfen.
- 13.10. Upstream-Kopie Fork #17 (Familienprüfung Export-/Import-/Dokument-Dateien, Fork #118), Befunde aus /code-review vor dem PR behoben (Commits 1ce21a057, a5e18bdb5):
  - L30 (bekannte Art): PROTECTED_RECORD_TYPES in active_storage_authorization.rb ist eine handgepflegte Liste; jetzt Reflection-Test
    über alle App-Modelle mit Anhängen (nur Logos von *Item, Account#logo, User#profile_image, ArchivedExport öffentlich).
    Falle: ActiveRecord::Base.descendants enthält Framework-Modelle (ActionText::RichText, ActionMailbox::InboundEmail); per
    const_source_location auf app/ begrenzen.
  - L7: Positivtest nur mit Kontoinhaber prüfte den Zweig „geteiltes Konto“ nicht; Test mit Mitglied auf geteiltem Konto ergänzt.
  - Offen (nicht in diesem PR): Transaktions-Anhänge nur nach Familie statt Kontofreigabe; getrackte Varianten/Vorschauen auf dem
    Disk-Pfad; ArchivedExport; API-Export-Download braucht Browser-Sitzung (L2).
- 13.10. (Fork 119, Sammeländerung nach Freigaberechten, Pre-PR-Review vor dem Upstream-PR behoben):
  - L2 (bekannte Art, durchgerutscht): Annotate-Felder im Web-Bulk standen als Sperrliste (`except(:date, :name)`);
    jetzt Erlaubt-Liste `slice(:notes, :category_id, :merchant_id, :tag_ids)` wie im Einzel-Formular.
  - L10 (neue Prüffrage): Wer den Scope einer Seite einschränkt (Kategorisier-Assistent: annotatable statt
    accessible), prüft auch Zähler und Menüpunkte, die auf diese Seite führen. Sonst zeigt „Kategorisieren (3)“
    auf eine Seite, die sofort „alles erledigt“ meldet. Cache-Key-Version dabei erhöhen (L9).
  - L4: Wird ein Sammel-Update in mehrere `bulk_update!`-Aufrufe geteilt (je Rechte-Stufe), gemeinsam in eine
    Transaktion legen, sonst bleibt bei einem Fehler die Hälfte geändert.
  - L7: Tests für gemischte Auswahl (full_control + read_write + nicht geteilt in einem Request).
- 14.10. (Datei-Zugriff Restlücken, Nachfolger von Fork #118; Befunde aus /code-review vor dem PR behoben):
  - L2 (bekannte Art): Getrackte Varianten (ActiveStorage::VariantRecord) und Vorschaubilder (Blob#preview_image) sind eigene
    Blobs mit eigenem record_type; eine Typ-Allowlist sieht sie nicht. Prüffrage ergänzt: Wird ein abgeleiteter Blob über die
    Anhänge seines Quell-Blobs geprüft (Blob-, Darstellungs- und Disk-Route)?
  - L7: Ablehnungstest für Varianten nur mit Fremdfamilie; ergänzt um Positivtest (Inhaber) und Mitglied ohne Kontofreigabe,
    sonst bliebe ein „immer ablehnen“-Guard grün.
  - L8: Datei direkt aus dem Controller senden (send_data + download) braucht ein rescue für ActiveStorage::FileNotFoundError.
- 14.10. (Fork #80 Edelmetalle, Claude-Review auf 541775b):
  - L2 (bekannte Art): Neue Member-Actions (edit_bullion, remap_bullion) bekamen set_holding, aber nicht die
    Schreibrecht-Prüfung; die Schwester-Action remap_security hatte sie. Prüffrage: Steht jede neue Action, die
    set_<model> bekommt, auch in der Permission-before_action, so wie ihre Schwester-Action?
- 14.10. upstream PR 4189 (Codex P2, CodeRabbit Minor, behoben in 168d9a5): L5 durchgerutscht in der down-Richtung:
  `add_index ... if_not_exists: true, algorithm: :concurrently` im down überspringt einen INVALID-Index.
  Prüffrage geschärft: Der valid_index-Guard (gültig behalten, ungültig droppen und neu bauen) gilt für JEDEN
  concurrent add, auch im down eines remove-Migrationsschritts.
- 14.10. upstream PR 4183 (Maintainer-Review r4266365259, Commit 0008ee5e2, Thread „Suchfeld am Handy im Dunkelmodus“):
  - L7 (bekannte Art, durchgerutscht): Der Farbtest deckte nur das Handy-Fenster ab, nicht die Desktop-Liste, die
    dieselbe Gem-Variable liest. Beim Nachtragen zeigte sich: Der Handy-Test maß zufällig den Hover-Zustand (Mauszeiger
    lag nach dem Klick über dem ersten Treffer), nicht die Auswahl. Prüffrage geschärft: Prüft ein Systemtest
    Zustandsfarben (Hover, Fokus, Auswahl), wird der Zustand explizit hergestellt (hover, focus) und jede Ansicht
    getestet, die dieselbe Regel nutzt (Desktop und Handy); vor dem Test per Selektor klären, welche CSS-Regel den Wert
    wirklich setzt. L13: PR-Text sagte „highlighted“, gemeint war „hovered“; nach dem Befund korrigiert.
- 14.10. upstream PR 4184, Maintainer-Review (jjmata), Fix c5f3b52:
  - L1 (bekannte Art: nil vs. 0): Der Editor behandelte einen gespeicherten Einstandspreis von 0 (z. B. geschenkte
    Anteile) wie „nicht gesetzt“ (`positive?`-Prüfung) und zeigte leere 0.00-Platzhalter. Die Prüfung stammte aus dem
    alten Code und ist beim Umbau unbesehen mitgewandert. Prüffrage geschärft: Beim Vorbelegen eines Felds nil
    (fehlt) und 0 (echter Wert) getrennt behandeln; `present?`/`positive?`/`zero?`-Prüfungen aus übernommenem Code
    gezielt mit dem Wert 0 testen.
- 14.10. Upstream 4194 (SimpleFIN-SSRF, Review Codex + Maintainer, 6 Befunde in 89443f66e behoben):
  - L2 (bekannte Art): Die neue Prüfung lief beim Neu-Verbinden erst im Job; der Controller meldete „aktualisiert“.
    Prüffrage geschärft: Wird eine Prüfung in einen Job verlegt, braucht jeder synchrone Einstieg (create, update) dieselbe Vorabprüfung.
  - L3 (bekannte Art): SSRF-Liste ohne Alibaba-Metadaten (100.100.100.200), Pinning über Proxy nur bei https (CONNECT),
    gepinnt nur auf die erste Adresse (kein Fallback). Prüffrage: Metadaten-Adressen aller großen Clouds, Proxy-Weg je Schema, Fallback.
  - L8: Verworfene Jobs (discard_on) ohne DebugLogEntry.
- Upstream 4181 (Review jjmata, 14.10.):
  - L7/N+1: Eine Liste, die je Eintrag umrechnet (Konvertieren-Auswahl), fragte den Wechselkurs je Wertpapier ab; bei fehlendem Kurs ein Provider-Aufruf pro Zeile. Gemeinsamer `rates`-Hash je Liste, Test erwartet genau einen Abruf.
  - Neu beachten: Auswahl- und Anzeige-Logik (welcher Preis, welche Klammer, welche data-Attribute) gehört in Helper oder Model, nicht in ERB-Partials oder `<% %>`-Blöcke.
- 14.10. (upstream PR 4188, Commit 1765d963e, 5 Befunde von Codex, CodeRabbit und Maintainer behoben):
  - L4 (bekannte Art, durchgerutscht): Debounce über Zeitstempel-Vergleich (`latest > scheduled_at`) lässt
    zwei Läufe durch, wenn Zeitstempel gleich sind oder Cache-Schreibvorgänge in falscher Reihenfolge ankommen.
    Prüffrage geschärft: Debounce-Marker immer als eindeutiges Token (UUID) mit Gleichheitsprüfung, nie Zeitstempel.
  - L4/L9: TTL des Markers muss Queue-Rückstau und Retries überdauern (hier 1 Tag), sonst laufen späte Jobs alle.
  - L21: Zweite Kopie eines vorhandenen Musters (IdentifyRecurringTransactionsJob) → gemeinsames Concern
    (app/jobs/concerns/family_debounce.rb) statt Kopie; der Fix greift dann an beiden Stellen.
  - L8: rescue loggt Backtrace wie der Nachbar-rescue (Maintainer-Hinweis).
- 14.10. upstream PR 4193 (OAuth-Client-Namen, 2 Review-Befunde behoben in 86e25a5):
  - L1 (bekannte Art, Codex): Bidi-Steuerzeichen (U+202E u. a.) wurden als \p{Cf} still entfernt; „‮elibom erus“ wurde als
    „elibom erus“ gespeichert, aber als „sure mobile“ angezeigt. Prüffrage geschärft: Zeichen, die die ANZEIGE umordnen
    (\p{Bidi_Control}), bei Namens-/Markenprüfungen ablehnen statt entfernen; nur unsichtbare Füllzeichen entfernen.
  - L1 (CodeRabbit): Doppelgänger-Map vergaß kyrillisch г (≈ r). Prüffrage: Map für JEDEN Buchstaben des geschützten Worts prüfen.
- 14.10. Fork 92 (Dashboard auf sortable-list, eigenes /code-review, Fix f11eb99):
  - L6 (bekannte Art: Touch): Beim Umzug auf einen gemeinsamen Controller übernahm das Dashboard das
    touchcancel-Abbrechen, aber nicht die Klasse `[-webkit-touch-callout:none]`, die die Reports-Abschnitte dafür
    tragen; iOS-Linkvorschauen hätten das Halten abgebrochen. Prüffrage geschärft: Wird eine Ansicht auf einen
    gemeinsamen Controller umgestellt, alle Markup-Voraussetzungen der bisherigen Nutzer (Klassen, data-action-Bindungen) mit übernehmen.
  - L7: Test-Helper rief `getControllerForElementAndIdentifier(document.querySelector(...))` ohne Null-Prüfung; fehlt
    das Element noch, wirft das JS statt zu warten. Im synchronize-Block immer erst auf das Element prüfen.
  - L6 (CodeRabbit, Fix dfcd798): Im Raster-Modus („nearest“) landete eine gezogene Karte immer VOR der nächsten
    Karte; hinter die letzte Karte ließ sie sich nie ziehen (Fehler schon im alten Dashboard-Controller, beim Umzug
    unbesehen übernommen). Prüffrage: Bei Drag-and-drop jede Zielposition durchspielen, auch „ganz ans Ende“, und
    bei übernommener Logik nicht nur Gleichheit mit dem alten Verhalten prüfen.
- 14.10. upstream PR 4193 Runde 2 (Maintainer, 2 Befunde behoben in 32c6b3c):
  - L1 (bekannte Art, dritte Runde): Wortsperre über scan(/[[:alnum:]]+/) ließ „S u r e“, „S.u.r.e“, „S-u-r-e“ durch, weil Trennzeichen
    das Wort zerlegen. Prüffrage geschärft: Bei Namens-/Markensperren immer auch Trennzeichen INNERHALB des Worts testen
    (Leerzeichen, Punkt, Bindestrich) und benachbarte Tokens zusammensetzen, solange sie ein Präfix des gesperrten Worts bilden.
  - L1: Doppelgänger-Map vergaß kyrillisch у; Map nicht nur pro Buchstabe, sondern je Buchstabe ALLE gängigen Doppelgänger prüfen.
- 14.10. (upstream PR 4192, Maintainer-Review jjmata, behoben in 0df07b4):
  - L21 (neue Prüffrage): Gibt es die Erlaubt-Liste eines Rechts schon an anderer Stelle (Einzel-Formular)? Dann
    eine gemeinsame Konstante (hier AccountShare::ANNOTATE_ENTRY_ATTRIBUTES / ANNOTATE_TRANSACTION_ATTRIBUTES)
    statt einer zweiten Liste, sonst laufen Einzel- und Sammelweg auseinander.
  - L14: Rechte-Aufteilung einer Auswahl in einer Abfrage (ID plus Schreib-Flag per pluck) statt zwei SELECTs.
  - L2: Methoden ohne eigene Rechteprüfung (Entry.bulk_update!) dokumentieren, was der Aufrufer vorher eingrenzen muss.
- 14.10. upstream PR 4204 „Passkey nur mit MFA-Code“ (Codex P2 behoben, Commit edbc926, Thread „MFA-Code vor Passkey“):
  - L23 geschärft (bekannte Art, durchgerutscht): „Erst beim Speichern verbrauchen“ reicht nicht, wenn die
    Browser-Zeremonie selbst eine Wirkung hat. navigator.credentials.create() legt mit residentKey: preferred
    einen discoverable Passkey auf dem Gerät an, auch wenn der Server ihn danach wegen falschem Code verwirft
    (belegt Speicherplätze auf Hardware-Keys). Prüffrage: „Hat der Schritt VOR der Prüfung eine Wirkung außerhalb
    des Servers (Gerät, Drittanbieter, E-Mail)? Dann vorher prüfen, ohne zu verbrauchen, und erst beim Speichern
    verbrauchen.“ Muster: User#otp_code_status (Antwort wie verify_otp, verbraucht nichts) in options.
  - L3 (Ratenlimit, CodeRabbit auf 4204, Commit 9968456): Prüft ein zweiter Schritt denselben Code, braucht jeder Schritt
    ein eigenes Limit (rate_limit name:). Ein gemeinsamer Zähler mit doppeltem Wert erlaubt über einen Schritt allein
    doppelt so viele Rateversuche. Prüffrage: „Kann man über jeden Einstieg allein öfter raten als das genannte Limit?“
- 14.10.2026 (upstream PR 4187, jjmata-Review, IDs im Buchungsformular): drei Befunde behoben. L21: Familienprüfung stand als Inline-Code in zwei Controllern, jetzt Concern Family::TransactionReferences (Prüffrage geschärft: Rechte-/Mandanten-Lookups nie inline im Controller, sondern als Model-Methode, die API/Bulk wiederverwenden). L8: eager Param-Prüfung machte aus dem 422-Re-Render (Anlegen ohne Konto) einen 404; Prüffrage: Läuft die neue Prüfung auch in Zweigen, die nur das Formular neu zeigen? L14: teurer Lookup bei jedem Auto-Submit auch für unveränderte Werte; Prüffrage: Auto-Submit-Formulare senden alle Felder, unveränderte Werte nicht neu prüfen.
- 14.10. (upstream PR 4205, CodeRabbit/Codex, in c572be9 behoben):
  - L14 (bekannte Art, durchgerutscht): Datei-Download per `send_data blob.download` lädt die ganze Datei in den Web-Worker.
    Prüffrage: Dateien aus Active Storage über `ActiveStorage::Streaming#send_blob_stream` ausliefern (Fehler danach nur noch als nackter Status).
  - L15 (bekannte Art): Endpoint liefert Binärdatei, rswag deklarierte weiter `produces "application/json"`. Für die 200-Antwort
    `metadata[:response][:content] = { "application/zip" => { schema: { type: :string, format: :binary } } }` setzen.
- 14.10. upstream PR 4190 (Passwortregeln, jjmata-Review, behoben in edad8fff6): L13/L2 durchgerutscht. Die Lücke
  „Passwortänderung prüft altes Passwort und Bestätigung nicht“ (Ursache wie unser eigener 72-Byte-Fix:
  `has_secure_password validations: false`) war bekannt und wurde bewusst auf den offenen Upstream-PR 3264 verwiesen.
  Der Maintainer erwartet sie im PR, der dieselbe Ursache an anderer Stelle behebt. Prüffrage geschärft: Behebt ein PR
  eine Folge einer gemeinsamen Ursache (hier validations: false), alle Geschwister-Folgen derselben Ursache im selben PR
  mit beheben, auch wenn ein anderer offener PR sie schon enthält (gleicher Code, damit der Merge trivial bleibt).
- 14.10. (upstream PR 4202, Commit 84af249): L18 (bekannte Art): Service-URL von host.docker.internal auf Compose-Namen
  umgestellt, aber NO_PROXY nicht mitgezogen (Codex). Prüffrage: Ändert sich ein interner Hostname, auch NO_PROXY/Proxy-
  Ausnahmen und Allowlists prüfen. L13 (bekannte Art): Kommentar „Platzhalter sicher, weil nur loopback“ war falsch, andere
  Container im Compose-Netz erreichen den Dienst auch (CodeRabbit). Hinweis: `${VAR:?}` in Compose bricht die ganze Datei,
  auch bei inaktivem Profil – Pflicht-Variablen nur für Dienste ohne Profil.
- 14.10. upstream PR 4191 (Token- und Sitzungs-Widerruf bei Passwortänderung, Commits f9fdc2d, d26f540):
  - L4/L2 (CodeRabbit): Prüfwert (Passwort-Fingerprint) wurde erst nach einem reload gebildet, also schon vom neuen
    Passwort. Prüffrage: Wird ein Vergleichswert direkt nach der Authentifizierung erfasst, vor jedem reload/Lock?
    Jeder Ausgabeweg (Token, Web-Sitzung, MFA-Abschluss) muss die Zugangsdaten im Lock erneut prüfen.
  - L13 (jjmata): Widerruf deckte nur OAuth-Tokens ab, Web-Sitzungen blieben nach Änderung/Reset aktiv. Prüffrage:
    „Welche ANDEREN Zugangswege hat das alte Geheimnis geöffnet (Sitzungen, API-Keys, Geräte)?“
  - L7: Negativtests (falsches altes Passwort, falsche Bestätigung) waren wegen `validations: false` auf main nicht
    rot zu bekommen; zweimal passiert. Vor dem Schreiben eines Negativtests prüfen, ob main die Prüfung überhaupt hat.
- 14.10. Fork 70 → Fork 124 (Regel-Aktion „Zeile an Notiz anhängen“, Commit 9e4075c):
  - L1 (CodeRabbit-Security-Review): Duplikatprüfung verglich den ganzen Wert mit einzelnen Notizzeilen; ein
    mehrzeiliger Wert (API, Regel-Import, Assistent) wurde bei jedem Lauf erneut angehängt. Prüffrage: Passt der
    erlaubte Wertebereich (auch über Nicht-UI-Wege) zur Idempotenz-/Duplikatprüfung, z. B. Zeilenumbrüche, \r\n?
- 14.10. (L7, Fork 85 → Fork 125): Testdatei umbenannt, Klassenname aber nicht (`PasswordsControllerTest` in `passwords_sso_only_test.rb`). Upstream 4190/4191 legen dieselbe Klasse an; Ruby öffnet sie erneut, deren `setup` (sign_in) liefe vor fremden Tests mit. Prüffrage: Klassenname passt zum Dateinamen und ist im Repo inklusive offener eigener PRs eindeutig?
- 14.10. Fork 72 → Fork 127 (Regeln sofort anwenden, upstream-Kandidat), /code-review:
  - L1/L8 (bekannte Art): Hinweise auf Seiten (Transaktions-Drawer, Regelliste) riefen `claimed_attributes` und
    `matching_scope` ohne Absicherung auf; eine importierte Regel mit unbekanntem Aktionstyp oder nicht unterstütztem
    Operator hätte die Seite mit 500 abbrechen lassen. Der Runner fing das schon ab, die neuen Hinweis-Wege nicht.
    Prüffrage: Ruft neuer Anzeige-Code dieselben Model-Methoden wie ein abgesicherter Hintergrundweg auf? Dann dieselbe
    Absicherung (hier `Rule::Action#reserved_attributes`, `Rule.hint_safely`) und ein Test mit kaputtem Import-Datensatz.
  - L8: `perform_later` liefert bei abgelehntem Enqueue `false` statt zu werfen; das `rescue` allein fing nichts. Und
    `update!`/`update_positions!` in One-Click-Aktionen ergaben 500 statt Hinweis.
  - L2/L7 (Nacht-Review 15.10.): Assistent-Funktionen und Kategorie-Schnellwahl als Auslöser verdrahtet, aber ohne Test.
    Prüffrage: Hat jeder im PR-Text genannte Einstiegspunkt einen eigenen Test, der den Aufruf belegt?
  - L1 (Nacht-Review 15.10.): Import setzte `apply_immediately` per `|| false` zurück, wenn ältere Exporte den Schlüssel
    nicht haben. Prüffrage: Neues Feld im Import nur zuweisen, wenn der Schlüssel vorhanden ist (`data.key?`).
- 14.10. Fork 33 → Fork 128 (Unique-Indizes je Transfer-Seite, /code-review vor Upstream):
  - L5/L29: Die Duplikat-Bereinigung in der Migration behauptete „wie Transfer#destroy!“, setzte aber jede freie Seite auf
    `standard`; destroy! tut das inzwischen nur bei bestätigten Transfers und nur für Transfer-Arten. Prüffrage: Kopiert
    eine Migration Modell-Verhalten (destroy!, confirm!), nach dem Rebase auf aktuelles main gegen den heutigen Modellcode
    abgleichen, auch für die Seite, die beim behaltenen Datensatz bleibt (Art ggf. neu ableiten).
  - L9: Roh-SQL-Änderungen an Transfers/Arten ohne `entries.updated_at`; Familien-Cache (entries_cache_version) merkt nichts.
    Prüffrage: Ändert Roh-SQL berichtsrelevante Daten, werden die Einträge mit angefasst?
  - L7: Datenlöschender Teil der Migration ohne Test; Assertion `count <= 1` war immer wahr. Prüffrage: Hat jede
    datenverändernde Migration einen Datentest (Unique-Index im Test kurz durch normalen ersetzen, DDL rollt zurück)?
  - L4/L8: Manuelles Verknüpfen (TransferMatchesController) lief bei RecordInvalid/RecordNotUnique in einen 500.
- 14.10. (L6, Fork 129 aus Fork 39): Auf das `close` eines bestimmten Dialogs warten reicht nicht. Ein Drawer, der im selben Frame durch den nächsten ersetzt wird, verlässt das DOM ohne `close`, und der zurückgehaltene Hinweis ging verloren. Prüffrage: Was passiert, wenn das Element, auf dessen Event ich warte, ohne dieses Event verschwindet? Lösung dort: `close` am document im Capture-Modus hören und erst ausliefern, wenn kein `dialog[open]` mehr da ist; Systemtest „Drawer ersetzt“.
- 14.10. (L16/L27, Fork 126 aus Fork 41, eigenes Review vor Upstream): (1) Eine neue „nur bei Eindeutigkeit“-Bedingung im exakten Zweig ließ den Fall ohne `next` in den Fuzzy-Zweig fallen; dort bekamen beide gleich hohen Vormerkungen denselben Fuzzy-Vorschlag. Prüffrage: Wenn ein Guard einen Treffer verwirft, läuft der Code danach in einen schwächeren Heuristik-Zweig weiter? (2) Re-Aktivierung (`excluded: false`) vor der Schutzprüfung: bei `import_locked` ohne `user_modified` blieb die Buchung vorgemerkt und wurde bei jedem Sync wieder ausgeschlossen (Schleife). Prüffrage: Läuft eine Zustandsänderung vor einer Schutzprüfung, die den Folgeschritt dann verhindert? (3) CodeRabbit wollte die Bereinigung bei `success: false` überspringen; abgelehnt, weil eine dauerhaft fehlerhafte Zeile die Bereinigung sonst für immer abschaltet (Begründung als Code-Kommentar). Prüffrage: Kann ein „nur bei Erfolg“-Gate durch einen dauerhaften Einzelfehler einen Wartungsschritt für immer blockieren?
- 14.10. (L4/L31, upstream 4209 aus Fork 34, Codex P2 ×3): Dedupe/„Anhängen an einen wartenden Datensatz“ verlängert. (1) Ein Laufzeit-Flag, das nur im Job-Argument lebt (balances_only), geht verloren, wenn eine volle Anfrage sich anhängt. (2) Ein wartendes Kind eines anderen Parents wurde übernommen; der neue Parent schloss ab, ohne auf es zu warten. (3) Ein Wartender kurz vor der 24-h-Stale-Grenze blieb anhängbar, die angehängte Anfrage wäre mit ihm verworfen worden. Prüffrage: Wenn eine Anfrage an einen bestehenden Datensatz angehängt wird: Geht dabei etwas verloren, das nicht in der Zeile steht (Job-Argumente, Parent-Zugehörigkeit), und kann ein Aufräumjob den Datensatz verwerfen, bevor er läuft?
  - Runde 2 (CodeRabbit, gleiches PR): Der erste Fix deckte jeweils nur den neuen Zweig ab, nicht den alten (sichtbares Fenster), und filterte nach `.first` statt davor. Prüffrage geschärft: Gilt der Fix für alle Zweige der Auswahl (alte und neue), und wird vor der Auswahl des ersten Treffers gefiltert, nicht danach? Laufzeit-Flags, die über die Auswahl entscheiden, beim Anlegen persistieren.
  - L13 (bekannte Art, durchgerutscht trotz 4013): Job- und Runner-Kommentar versprachen „exakt wie im nächtlichen
    Lauf“, obwohl nächtliche Regeln oberhalb nur gematcht, nicht ausgeführt werden (Umbenennung oberhalb wird erst
    nachts gesehen). Gleicher Befund wie Codex P2-2 auf 4013. Behoben in 30ec017 (Text + Test). Prüffrage: Vor dem
    Upstream-Push die Review-Befunde des Vorgänger-PRs (gleiche Klasse/Datei) gezielt gegen den neuen Code prüfen.
- 14.10. (L6, upstream 4210, Codex 2× P2): Trotz Nachtrag oben kam ein weiterer Weg ohne `close` durch: ein Stream ersetzt den Modal-Frame (SimpleFIN), und Turbo ruft das überschriebene `event.detail.render` erst nach dem nächsten Paint auf, wenn der Dialog schon zu sein kann. Prüffrage geschärft: Wer etwas bis zu einem Ereignis zurückhält, prüft (a) Entfernen ohne Ereignis (MutationObserver solange etwas wartet) und (b) ob das Ereignis schon vorbei ist, wenn der Rückruf später läuft (beim Einreihen nachprüfen).
- 14.10. (L4/L1, upstream 4215, Codex): (1) Sperr-Reihenfolge: Bereinigung sperrte `entries` vor `transactions`, ein Transaction-Save (touch auf Entry) tut es umgekehrt → Deadlock-Gefahr. Prüffrage: Sperrt neuer Code mehrere Tabellen, in derselben Reihenfolge wie die normalen Saves/Touches? (2) Marker per `will_save_change_to_x?` gelöscht: Schreibt der Nutzer denselben Wert (veraltete Seite), bleibt der Marker. Prüffrage: Hängt eine „Nutzer hat entschieden“-Logik nur an Wertänderungen statt an der Schreibabsicht?
  - Runde 2 (CodeRabbit Minor, Fix 492b5f0): Der Marker wurde über das geladene `entryable` gelöscht. War die Transaktion vor dem Sync geladen, kannte sie den Marker nicht und speicherte nichts. Prüffrage: Räumt ein Callback Daten auf, die ein anderer Prozess geschrieben haben kann, dann direkt auf der gespeicherten Zeile (SQL), nicht nur auf dem geladenen Objekt.
  - Runde 3 (CodeRabbit Minor im Review-Text, Fix f94ad33): Mehrdeutigkeit war nur auf einer Seite abgedeckt (zwei Vormerkungen), nicht bei zwei exakten Buchungen; die fielen in den Fuzzy-Zweig. Gleiche Fehlerart wie (1) oben. Prüffrage: Für jede Mehrdeutigkeitsregel beide Seiten (n:1 und 1:n) prüfen.
  - L1/L10 (CodeRabbit auf Fork 124, Commit a9a2bf7): Notiz-Aktionen mit leerem Wert änderten nichts, reservierten
    aber trotzdem das Feld („top rule wins“) und sperrten Regeln darunter. Bekannte Art (bei Name-Aktion schon über
    `actionable?` gelöst). Prüffrage: Hat jede neue Regel-Aktion ein `actionable?`, das genau die No-op-Werte ablehnt?
- 14.10. (L8, upstream 4219, CodeRabbit Minor, Fix 3ba8a6c): Meldungs-Dedup mit festem Deckel (500 Schlüssel je Prozess) verstummte danach dauerhaft; ein lange laufender Prozess hätte neue Fehlstellen still verschluckt. Prüffrage: Hat ein Dedup/Rate-Limit für Fehlermeldungen einen Weg zurück (leeren, ablaufen, verdrängen), statt nach dem Deckel für immer zu schweigen?
- 14.10. upstream PR 4216 (Codex, Runde 1, Commit 9c9175cc0):
  - L5/L4: Datenbereinigung in einer Online-Migration las den Status vor der Transaktion und ohne Sperre; ein während
    der Migration bestätigter Transfer wäre mit altem Status gelöscht worden. Prüffrage: Werden Zeilen, nach deren Zustand
    eine Migration entscheidet, in derselben Transaktion per FOR UPDATE gelesen?
  - L1/L27: Eindeutigkeit „eine Buchung, ein Transfer“ nur je Spalte; dieselbe Buchung konnte Eingang des einen und Ausgang
    des anderen Transfers sein (Vorzeichenkorrektur durch Provider), und der Matcher prüfte nur dieselbe Rolle.
    Prüffrage: Gilt eine Eindeutigkeit über mehrere Rollen/Spalten hinweg, und prüfen Matcher und Bereinigung alle Rollen?
  - L29: Kind-Reset übersprang Beine, die nur noch ein Pending-Transfer hielt. Prüffrage: Zählt beim „wird noch benutzt“
    nur ein Datensatz, der die Wirkung tatsächlich gesetzt hat (bestätigt), oder jeder?
  - L1/L22 (eigenes Claude-Review auf Fork 124, Commit 2590bda): Idempotenz nur zwischen Regeln geprüft, nicht
    zwischen zwei Aktionen derselben Regel (Ersetzen + Anhängen schrieb die Notiz bei jedem Lauf neu). Prüffrage:
    Konvergiert jede erlaubte Kombination von Aktionen in EINER Regel bei wiederholten Läufen? Sonst Validierung.
- 15.10. Fork 92 (Fork-PR-Job Claude-Review, Fix 7a40ea3):
  - L6 (bekannte Art: UI-Zustand): dragOver/drop liefen auch für Drags von außen (Datei, Text); ohne gezogenes
    Element fügte `Element.before(null)` den Text „null“ ein und speicherte. dragEnd ließ das zuletzt gezogene Element
    stehen, sodass ein späterer Fremd-Drop eine alte Karte verschob. Prüffrage: Bei Drag-and-drop Ereignisse von
    außen (Datei, Text, andere Liste) durchspielen und Zustand am Ende jedes Wegs (drop, dragend, touchcancel) zurücksetzen.
- 15.10. upstream 4205 (jjmata, Fix 2229197):
  - L2 (bekannte Art: Pfadliste unvollständig): Die Pfad-Tabelle prüfte nur die vier gemeldeten Lücken. FamilyExport#export_file
    lief weiter offen über die Blob-Routen, weil der Schutz dafür nur im Parallel-PR 4203 stand. Prüffrage: Steht jeder
    Datensatztyp mit has_one_attached/has_many_attached auf diesem Branch selbst geschützt oder begründet frei, unabhängig
    von noch offenen Nachbar-PRs?

- 15.10. (upstream PR 4206, Codex P1/P2, CodeRabbit, jjmata):
  - L9/L2 (bekannte Art, durchgerutscht): Gespeicherte Ableitungen (Insight-Body, LLM-Text) überleben eine
    Rechteänderung, wenn der Vergleichsschlüssel nur Zahlen-Buckets enthält. Prüffrage: Steht im gespeicherten
    Vergleichswert auch die Menge, aus der gerechnet wurde (z. B. Digest der Konto-IDs)? Was passiert mit
    Bestandszeilen beim Deploy? Lösung hier: accounts_digest in metadata, nur Digest geändert = Text neu, Status bleibt.
  - L10: Ein Guard „gibt es Daten?“ muss dieselben Filter nutzen wie die Rechnung (hier
    IncomeStatement#eligible_accounts), sonst greift er bei ausgeschlossenen/deaktivierten Konten nicht.
- 15.10. upstream 4209, Runde 3 (jjmata + CodeRabbit Minor im Review-Text, Fix 3552a8f):
  - L8/L4: Session-Advisory-Lock wird nur bei Verbindungsende frei; ein hängender (nicht abgestürzter) Job hielt
    ihn auch nach „stale“ durch den Cleaner, der Syncable blieb bis zum Worker-Neustart blockiert. Fix: Cleaner beendet
    die haltende PG-Sitzung, wenn sie über 1 h idle ist. Prüffrage: Hat jede neue Sperre einen Weg, der sie bei
    Hängen (nicht nur Absturz) freigibt, und passt er zur bestehenden „abgeschrieben“-Logik?
  - L4 (bekannte Art): Nach dem Erwerb der Sperre wurde der Zustand nicht neu gelesen (start! auf veraltetem
    Objekt, Fenster einer angehängten Anfrage fehlte). Prüffrage: Nach jeder Sperre, auf die gewartet werden kann,
    Datensatz neu laden und ALLE Vorbedingungen (auch Löschungs-Guards) unter der Sperre prüfen.
- 15.10. upstream PR 4207 (L9, Codex P2, Fix 4ec92a1): Cache-Key je Nutzer über `Current.account_share_version` (Anzahl + neuestes updated_at der Freigaben) blieb gleich, obwohl sich die sichtbaren Konten änderten: `reassign_owned_accounts!` setzt owner_id per update_all (kein Freigabe- und kein Konto-Zeitstempel), und eine ersetzte Freigabe mit älterem Zeitstempel hält Anzahl und Maximum. Lösung: Digest der tatsächlich verwendeten Konto-Zeilen in den Key. Prüffrage: Ist eine Cache-Version aus count/max(updated_at) gebaut, kann sie für eine andere Menge gleich bleiben (update_all, insert_all, Besitzwechsel)? Wenn die Menge ohnehin geladen wird, die Menge selbst hashen.
- 15.10. upstream 4216, jjmata (Fix 29f96567d):
  - L4/L10 (bekannte Art, durchgerutscht): Der Rollen-Fall (Buchung ist Zufluss eines Transfers und Abfluss eines
    anderen) war nur im Auto-Matcher und in der Migration abgedeckt, nicht im manuellen Abgleich. Prüffrage: Wenn eine
    neue Invariante nicht per Index geht, steht sie im Modell (alle Schreibwege) statt in einem einzelnen Aufrufer?
  - Rails: errors.added?(:attr, :taken) ist false für Uniqueness-Fehler (die tragen value: als Option);
    errors.of_kind? verwenden.
- 15.10. upstream PR 4201 (Passwortänderung drosseln; Codex 2× P2, CodeRabbit, Maintainer; behoben in 2e9b611):
  - L2 (bekannte Art, durchgerutscht): Drossel-Schlüssel nahm den Sitzungsinhaber, geprüft wird aber `Current.user`
    (bei Impersonation der impersonierte Nutzer). Prüffrage geschärft: Jeder Schlüssel für „wessen Passwort/Code
    wird geprüft“ folgt `Current.user` inkl. Impersonation; Test mit laufender und beendeter Impersonation.
  - L3 (neue Art): IP-Drossel vor einem Endpunkt hinter Login zählte auch Anfragen ohne gültige Sitzung, die nie
    eine Prüfung erreichen. Folge: Fremde hinter derselben IP (NAT) sperren angemeldete Nutzer aus. Prüffrage: Zählt
    eine Drossel nur Anfragen, die die geschützte Prüfung tatsächlich erreichen? Test: ohne/gefälschtes/abgelaufenes
    Cookie → kein IP-Schlüssel.
- 15.10. upstream PR 4208 (Passwortänderung bei SSO-only sperren; Maintainer; behoben in 5fbc856):
  - L2 (bekannte Art, durchgerutscht): Sperre nur auf der eigenen Passwortseite, der Admin-Weg
    (Admin::UsersController#update + Passwortfeld in der Nutzerliste) setzte weiter Passwörter. Prüffrage geschärft:
    Bei jeder Regel „X darf nicht gesetzt werden“ alle Schreibwege des Attributs suchen (grep auf das Attribut in
    app/controllers, inkl. Admin, API, Reset, Registrierung) und je Weg entscheiden: gleiche Regel oder begründete Ausnahme.
  - Runde 4 (CodeRabbit Minor, Fix 300be2bf8): Schlug das Freigeben der Session-Sperre fehl, ging die Verbindung
    mit noch gehaltener Sperre zurück in den Pool. Prüffrage: Wird eine Verbindung, deren Sitzungszustand (Sperre,
    SET, temp. Tabelle) nicht sicher zurückgesetzt werden konnte, verworfen (throw_away!) statt gepoolt?
  - L4 (CodeRabbit Major, Fix d98cd7b62): Eine neue Modell-Validierung „gibt es schon …?“ ist check-then-insert.
    Prüffrage: Wenn kein Index die Invariante abbildet, sperrt die Prüfung vorher (pg_advisory_xact_lock je
    betroffenem Datensatz, sortiert), damit ein paralleler Schreiber wartet und den Commit sieht?

- **15.10.2026, Fork 130 (Gruppensumme/Sparkline), eigenes /code-review:** L9 geschärft: Ändert sich die Rechenlogik hinter einem gecachten Fragment mit `skip_digest: true` (Sidebar `account_sidebar_tabs_vN`), Version hochzählen. L7 geschärft: Cache-Tests laufen in der Testumgebung gegen `:null_store` und prüfen dort nichts; für Cache-Key-Tests `Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)` und ohne den Key-Fix einmal rot laufen lassen. L7: Negative Query-Regex nach Scope-Änderung (DISTINCT, JOIN) an die neue Form anpassen, sonst trifft sie nie.

- **15.10.2026, Fork 131 (Kontonummern maskieren), CodeRabbit Major, Fix b4ca3887d:** L1 geschärft: Schreibt eine Datenmigration erzeugte Werte um (z. B. Standard-Kontonamen), muss jede Namensform dieselbe Regel bekommen. Hier blieb „Mein Sparkonto Fio banka <Nummer>“ unmaskiert, weil nur die Klammer-Form eigene Wörter davor erlaubte. Prüffrage: Hat jede Form (Klammer, Präfix, nackte ID) einen Test mit eigenem Text des Nutzers davor?
- **15.10.2026, Fork 132 (Restlücken Verschlüsselung), eigene Nachprüfung, behoben vor Merge:** L17 geschärft: Die Duplikat-Suche nach PR-Titeln übersah, dass upstream 3510 dieselbe Spalte (EnableBankingAccount#iban) schon verschlüsselt, dort deterministisch. Ein zweites `encrypts` mit anderem Schema hätte die Spalte nach beiden Merges unlesbar gemacht. Prüffrage: Für jede Spalte, die der PR anfasst, `git grep '<spalte>'` auf allen offenen PR-Branches (auch eigenen und gestapelten), nicht nur Titel. L3/L18 erneut: Neues `encrypts` auf eine Spalte mit Altdaten bekommt `support_unencrypted_data: true` je Spalte, auch wenn eine Migration den Bestand verschlüsselt (Nachzügler-Prozesse, später gesetzte Schlüssel).
- **16.10.2026, upstream PR 3997 (Sidebar-Sparklines), Merge mit main nach upstream PR 3576, eigenes /code-review:** L9 erneut: Ein Merge, der das Markup eines `skip_digest`-Fragments gegenüber beiden Seiten verändert (main v3, Branch v4), braucht eine neue Version (v5), auch wenn keine Seite allein sie bräuchte. L7 geschärft: Eine Abwesenheits-Prüfung („kein Timeout-Hinweis“) auf genau das Element begrenzen, um das es im Test geht, sonst lässt jede andere langsame Anfrage den Test wackeln.
- **16.10.2026, upstream PR 4184 (Einstandswert-Editor), jjmata CHANGES_REQUESTED, Fix 4caf207 (Fork 133):** L1 geschärft: Ein Feld mit fester Anzeige-Präzision (`precision: 2`) rundet über `money_field` auch eingefügte Werte. Bei Preisen pro Stück unter einem Cent (0,0049 × 10.000) wird daraus 0. Prüffrage: Liefern Tippen und Einfügen bis zum gespeicherten Wert dasselbe Ergebnis? Einen Systemtest für beide Wege schreiben.
- **16.10.2026, upstream PR 3997, rote CI (test_system) nach Merge mit main, Fix 9eb020e8a:** L7/L26 geschärft: Ein Timer, der auf ein Abschluss-Ereignis wartet (hier `turbo:frame-load`), muss beim Auslösen prüfen, ob die Arbeit inzwischen fertig ist (`busy` weg). Turbo nimmt `busy` beim Ende der Anfrage weg, feuert `frame-load` aber erst nach dem Rendern; auf einem ausgelasteten Haupt-Thread überschrieb der Timeout-Hinweis die gerade geladene Sparkline. Prüffrage: Kann das Abschluss-Ereignis später kommen als das tatsächliche Ende, und überschreibt der Timer dann ein Ergebnis?
- **16.10.2026, upstream PR 4210 (Regel-Popup), jjmata-Hinweis, Fix c7442aa:** L6 geschärft: Wer auf „Dialog zu“ wartet, muss alle Wege abdecken: `close`-Event, Entfernen aus dem DOM UND Entfernen des `open`-Attributs (schließt in Chromium ohne `close`). MutationObserver dafür mit `attributes: true, attributeFilter: ["open"]`.
- **16.10.2026, upstream PR 4203 (Datei-Zugriff), jjmata-Nitpick, Fix d24895a (gleich in 4205 5c37f07):** L8 geschärft: Neue Rechte-Prüfungen neben bestehenden übernehmen deren rescue-Liste (hier `NoMethodError` wie `transaction_attachment_authorized?`), damit sie gleich „fail closed“ mit 404 statt 500 enden. Kopien derselben Methode in Parallel-PRs gleich halten.
- **16.10.2026, upstream PR 4202 (AI-Compose-Defaults), CodeRabbit Minor, Fix 67c4012:** L1 (Doku): Ein Hinweistext, der eine Sicherheitseigenschaft für „die Dienste“ behauptet („nur auf Loopback“), muss gegen alle `ports:`-Einträge der Datei geprüft werden; hier blieben Sure (3000) und Pipelock (8889) auf allen Schnittstellen. Prüffrage: Nennt jede pauschale Sicherheitsaussage in Kommentaren oder Doku die betroffenen Dienste namentlich, und stimmt sie mit `docker compose config` überein?
- **16.10.2026, Fork 131 (Kontonummern maskieren), eigenes Review vor Freigabe, Fix d1615512f:** L5 geschärft: In einer Migration ist `quote(x)` nicht `connection.quote(x)`. `Migration#quote` reicht per method_missing das erste Argument als Tabellenname weiter, `quote(nil)` liefert `''` statt `NULL`. Prüffrage: Nutzt jede Migration mit selbst gebautem SQL `connection.quote`, und gibt es einen Test mit nil-Wert? L3 erneut: Wer ein Leck in neuen Importen schließt (Mercury-`details` in Notizen), prüft den Bestand und räumt ihn per Migration auf, dabei gesperrte (vom Nutzer bearbeitete) Felder auslassen.
- 16.10.2026, upstream PR 3020 (Nachtjob-Review + eigenes Review auf high, behoben in b273b56):
  - L2/L4: Sperre nur für „Split anlegen“ zentralisiert; „Split bearbeiten/aufheben“ (Web und API) liefen weiter ohne bzw. mit eigener Sperre. Prüffrage: Für jede Schreibaktion auf dieselbe Zeile (anlegen, ändern, löschen) dieselbe Sperre in derselben Reihenfolge?
  - L1: Prozent-Anteile auf 2 Stellen gerundet ergaben Bruchteile von Yen; Rundung nach Währung, aber gedeckelt auf die Spaltenskala (Krypto hat 8 Stellen, Spalte 4). Unbekannter Währungscode darf die Schleife nicht abbrechen.
  - L8: name.blank? wirft bei kaputtem UTF-8 → 500. Text-Gültigkeit vor blank?/length prüfen.
  - L2/L22: JSON-String verbirgt NUL als \u0000; Textprüfung auf dem dekodierten Wert, gemeinsam für beide Importer.
- **17.10.2026, upstream PR 4185 (Verkauf nur aus Bestand), PR-Check-Review (high), behoben lokal:** L1 geschärft: Anzeige einer Menge mit fester Präzision (`precision: 8`) rundet AUF, wenn die Spalte mehr Stellen speichert (scale 18); wer den angezeigten Bestand verkauft, wird abgelehnt, und die Meldung nennt auf beiden Seiten dieselbe Zahl. Prüffrage: Hat jede angezeigte Menge, die der Nutzer zurück eingeben kann, die volle Spaltenpräzision? L8 geschärft: `Date.iso8601` wirft ab 129 Zeichen einen reinen `ArgumentError`, kein `Date::Error`; `rescue Date::Error` reicht für Params nicht. L3 erneut: Neue Warnungen mit Mengen brauchen `privacy-sensitive` wie die Werte daneben.
- **17.10.2026, upstream PR 4205 (Datei-Zugriff), PR-Check-Review (high), behoben lokal:** L8 geschärft: Nach `send_blob_stream` (ActionController::Live) ist die Antwort schon geschrieben; ein `rescue` mit `render json:` wirft `DoubleRenderError`. Prüffrage: Prüft jedes rescue nach einem Stream `performed?`, bevor es rendert?
- **17.10.2026, upstream PR 4184 (Einstandswert-Editor), PR-Check-Review (high), behoben lokal:** L10 erneut: Der Editor wertete einen gespeicherten Einstandswert 0 als echt, `Holding#avg_cost` nur, wenn er gesperrt ist; unverändertes Speichern sperrte so 0 über dem berechneten Wert. Gleiche Regel an einer Stelle (`Holding#known_cost_basis`) für Anzeige und Berechnung.
- **17.10.2026, upstream PR 3997 (Sidebar-Sparklines), PR-Check-Review (high), behoben lokal:** L6/L26 geschärft: Ein Guard „nur auslösen, solange `busy`“ deckt auch den Fehlerfall zu: Turbo nimmt `busy` nach einem Netzfehler weg, ohne `turbo:frame-load`. Prüffrage: Hat jeder Timer, der auf ein Abschluss-Ereignis wartet, auch einen Weg für den Fehlerfall (`turbo:fetch-request-error`)?
- **17.10.2026, upstream PR 3020 (Split-Regel), PR-Check-Review (high), behoben lokal:** L1: Feste Anteile ohne Prüfung der Nachkommastellen werden gerundet gespeichert, die Kinder ergeben dann nicht mehr den Elternbetrag. L13: Eine Auswahl „kein Händler“, die in Wahrheit den Händler der Hauptbuchung übernimmt, verspricht etwas anderes, als sie tut; Beschriftung nach dem tatsächlichen Verhalten. L14: Zeilen, die nie passen (Split-Kinder, ausgeschlossene), schon in der Abfrage ausfiltern statt je Zeile prüfen.
- 17.10. upstream 4205 (PR-Check + CodeRabbit, Fix 190c16f):
  - L2 (bekannte Art: fail-open bei fehlendem Datensatz): `disk_service_blob` gab bei gültig signiertem Disk-Key ohne
    Blob-Zeile nil zurück, und `return unless authorized_blob` ließ die Datei ohne Prüfung durch (nachgestellt: 200).
    Prüffrage: Führt jedes "nicht gefunden" in einer Autorisierungs-Kette zu 404 statt zum Überspringen der Prüfung?
  - Neu (Parallel-PRs): Der PR-Text behauptete "merged sauber mit 4203", geprüft war das nur vor einem späteren Commit.
    Prüffrage: Nach jedem Push `git merge-tree` gegen alle offenen Nachbar-PRs auf derselben Datei wiederholen, und
    Merge-Aussagen im PR-Text nur mit dem geprüften Commit machen. Gemeinsame Prüfungen in getrennten Zeilen halten
    statt dieselbe Liste/Case-Verzweigung in beiden PRs zu ändern.
- **17.10.2026, upstream PR 4184 (Einstandswert-Editor), PR-Check, Fix 3ec289e:** L10 geschärft: Speichert das Modell eine andere Größe als das Formular sendet (Preis pro Anteil mit 4 Stellen vs. auf Cent gerundetes Total), entsteht beim Umrechnen ein Rundungsfehler, auch beim unveränderten Speichern. Prüffrage: Sendet das Formular genau die gespeicherte Größe mit deren Nachkommastellen?
- **17.10.2026, upstream PR 3020 (Split-Regel), PR-Check-Befunde a–c, behoben lokal:** Neu (Regel-Aktionen, die Datensätze anlegen): Die Split-Aktion erzeugte Kinder, die weder beansprucht noch gesperrt waren; eine tiefere Kategorie-Regel überschrieb deren Kategorie im selben und jedem späteren Lauf. Prüffrage: Was eine Aktion auf neu angelegten Datensätzen setzt, ist es gegen tiefere Regeln geschützt (Sperre/Claim)? Und: Ergibt jede andere Aktion in derselben Regel nach/vor dieser Aktion noch Sinn, sonst Kombination per Validierung verbieten. Und: Bietet der Assistent/MCP eine neue Aktion mit beschreibbarem Wertformat an, sonst dort sperren.
- 17.10. upstream 4216 (CodeRabbit "Include cross-role links", Fix 81a886bfe):
  - L4/L10 (bekannte Art, durchgerutscht): Nach Einführung der Rollen-Validierung im Modell prüfte die Rettung im
    TR-Settlement (`settlement_side_linked?`) weiter nur gleiche Rollen; ein `:taken` aus dem Rollentausch wurde neu
    geworfen und ließ das Event scheitern. Prüffrage: Wenn eine Validierung neue Ablehnungsgründe bekommt, deckt jeder
    `rescue RecordInvalid`/„schon verknüpft?“-Check der Aufrufer dieselbe Bedingung ab wie die Validierung bzw. der Vorab-Check?
- **18.10.2026, upstream PR 4184 (Einstandswert-Editor), PR-Check-Review (high), behoben lokal:** L10 erneut: Nach „unbekannter Wert lässt die Felder leer“ wandelte der Controller ein leeres Feld per `"".to_d` in 0 und sperrte es; Speichern ohne Eingabe sperrte so wieder 0. Prüffrage: Wird ein leerer Parameter vor `to_d`/`to_i` als „fehlt“ erkannt (`presence`), wo 0 ein echter, gesperrter Wert ist?
- **19.10.2026, Fork 135 (Kursquelle im Positionsfenster), /code-review vor PR, behoben vor Push:** L7: Ein Test „offline ohne Anbieter → keine Quelle“ war auch ohne den Offline-Zweig grün, weil in der Testumgebung gar kein Anbieter aktiv ist; erst ein gestubbter Standardanbieter trennt die Fälle. Prüffrage: Läuft der Negativfall gegen eine Umgebung, in der der Fallback tatsächlich etwas liefern würde? L11: Neue Keys standen nur in en/de, Nachbar-Keys in 17 Sprachen. L13: „(deaktiviert)“ auch für aktivierte Anbieter ohne API-Key; Beschriftung nach tatsächlichem Zustand („nicht verfügbar“). L21: Anbietername an drei Stellen verschieden geschrieben (humanize vs. Übersetzung); eine Helper-Methode für alle.
- **19.10.2026, upstream PR 3020 (Split-Regel), PR-Check nach main-Merge, behoben lokal:** Neu (Merges): main und der PR fügten in `Rule::Runner#record_failure` fast denselben `DebugLogEntry.capture`-Block ein; git hat beide ohne Konflikt übernommen, jeder Fehler wurde doppelt geloggt. Prüffrage: Nach jedem main-Merge die automatisch zusammengeführten Stellen, die beide Seiten berührt haben, auf doppelte Blöcke prüfen (Log-Einträge, Validierungen, Callbacks), nicht nur die Konfliktstellen.
- **20.10.2026, upstream PR 4184 (Einstandswert-Editor), Maintainer-Review gariasf + /code-review max, behoben in a4baec2/1be30f2:** L33/L10 erneut: Leeren des Gesamtfelds schrieb per `parseLocaleFloat("") = 0` „0.00“ in das gesendete Pro-Stück-Feld. Prüffrage: Setzt ein berechnetes Nachbarfeld bei leerer Quelle ebenfalls leer statt 0? Neu (Turbo): `data-turbo-confirm` auf einem Formular mit `data-turbo="false"` ist toter Code; Prüffrage: Läuft jedes `turbo_confirm` wirklich über Turbo, und gibt es einen Systemtest, der den Dialog sieht? Folgefehler beim Aktivieren: Der Klick im Bestätigungsdialog schloss das umgebende DS-Popover (Outside-Click). Prüffrage: Wenn ein Dialog über einem Popover/Menü aufgeht, schließt ein Klick darin das Popover? Neu (Privacy): neue Eingaben mit Beträgen/Mengen brauchen `privacy-sensitive privacy-sensitive-interactive`. Neu (A11y): Schließen per Cancel muss den Fokus auf den Auslöser zurückgeben. L21: ein Sonderschalter (`round_paste:`) statt der vorhandenen Regel (`step="any"` = ungerundet) ist unnötige API; erst prüfen, ob eine bestehende Bedingung den Fall schon trägt.
- 20.10.2026 Wochenauswertung (99 Befunde, 30 PRs; Upstream 82 in 25 PRs, Fork 8, Bugfix-Rückblick 9; Liste befunde-woche-2026-10-20.md; 30 durchgerutscht, keine neue Lektion):
  - L6: Bricht `data-turbo-confirm` unter `data-turbo=false` weg (wirkt nur bei Turbo-Submits)? (upstream PR 4184) Wird ein Element entfernt statt geschlossen (Frame-Replace) und fehlt so das close-Ereignis? (upstream PR 4210) Schluckt ein Redirect in einem Modal-Frame die Flash-Meldung, braucht die Antwort einen Frame-Ausbruch? (Bugfix 3849) Hängen Timer und Ladezustände am Ereignis, das sie messen (Lazy-Frames: before-fetch-request)? (Bugfix 3576) Funktioniert Drag-and-drop auch hinter dem letzten Element? (Fork 92)
  - L12: Klickflächen mindestens 36 px, Größen wie vorhandene Paare auf main? (upstream PR 4184)
  - L10: Liest die UI materialisierte Tabellen (Holdings), die erst nach dem Sync stimmen? (upstream PR 4185)
  - L9: Enthält der Upsert-/Dedupe-Schlüssel jedes Feld, das in gespeicherten Text einfließt? (upstream PR 4185) Ist ein Versionszähler aus count/max(updated_at) wirklich monoton, oder wird der Schlüssel erst nach dem Lesen gebildet bzw. eine Generation geführt? (upstream PR 4207)
  - L8: Überleben zeitbasierte Marker (Cache-TTL) Warteschlangen-Verzug und Retries? (upstream PR 4188) Wird vor dem Einreihen synchron validiert, nicht erst im Job? (upstream PR 4194) Wird vor dem Aufräumen auch eine Rückgabe success:false geprüft, nicht nur Ausnahmen? (Fork 126)
  - L5: CONCURRENTLY mit if_not_exists: wird ein INVALID-Index erkannt und neu gebaut, auch in down? (upstream PR 4189) Sperrt eine Bereinigung in einer Online-Migration die Zeilen und liest den Status innerhalb der Transaktion? (upstream PR 4216)
  - L3: `has_secure_password validations: false`: werden Abfrage und Bestätigung selbst geprüft? (upstream PR 4190) SSRF: umgeht ein Umgebungs-Proxy das IP-Pinning, werden Metadaten-IPs aller Clouds (169.254.169.254, 100.100.100.200) immer gesperrt und IPv4-übersetzbare IPv6 normalisiert? (upstream PR 4194, Fork 117) Rack::Attack-Schlüssel vor der Anmeldung: verbrauchen unangemeldete Anfragen das Budget echter Nutzer? (upstream PR 4201)
  - L2: Zählen halb fertige Anmeldungen (MFA-Zwischenzustand in der Session) als eigener Pfad? (upstream PR 4191)
  - L1: Unicode-Confusables-Tabelle statt Handliste? (upstream PR 4193, früher Fork 91) Wird vor dem Normalisieren geprüft bzw. abgelehnt, wenn das Original gespeichert und angezeigt wird (Bidi)? (upstream PR 4193) Steht ein Modus nur in Job-Argumenten und ist so für Dedupe/Join unsichtbar, statt an der Zeile gespeichert? (upstream PR 4209) Sind vor einem `update_all` geladene Assoziationen danach veraltet? (upstream PR 4215) Brauchen neue Aktionstypen `actionable?` für leere Werte wie in upstream PR 4013? (Fork 124)
  - L4: Gleiche Sperrreihenfolge überall (Transaktion vor Entry, wie touch: true)? (upstream PR 4215) Eindeutigkeit über zwei Rollen-Spalten braucht mehr als zwei Einzelspalten-Indizes. (upstream PR 4216)
  - L19: Der Maintainer will `*.example.*`-Dateien nicht gehärtet haben; solche PRs nicht öffnen. (upstream PR 4202, geschlossen)
  - L23: Laufen Server-Prüfungen, die scheitern können, vor unumkehrbaren Client-Schritten (Authenticator speichert ein Credential)? (upstream PR 4204)
  - Review-Prompt (Teil D): Die durchgerutschten Befunde fallen alle unter vorhandene Schritte (Lektionsfragen L1–L12, L23); kein Vorschlag für Teil A.

- 20.10.2026, Fork 137 (Folge-PR zu upstream PR 4184), Vor-PR-Review, behoben:
  - L3/L21 (bekannte Art): Privacy-Klassen nur im Drawer ergänzt; `sync_prices.turbo_stream.erb` rendert den Marktwert als Kopie ohne Unschärfe neu. Prüffrage: Gibt es Turbo-Stream-, Broadcast- oder Partial-Kopien derselben Zeile (`rg dom_id(...:market_value)`), die beim Ändern der Klasse mitgezogen werden müssen?
  - L11 (bekannte Art): Neuer Key nur in Locales mit dem Nachbar-Key `edit_security`; nl, nb, pt-BR, ro übersetzen die Zeile, hatten ihn nicht. Prüffrage: Key in jede Locale, die das Label der Zeile übersetzt. Außerdem: CRLF-Locale-Dateien (nb.yml) beim Bearbeiten nicht nach LF umschreiben (`git diff --stat` prüfen).
  - L6/L11 (neu sichtbar): Bisher tote Rückfragen wurden erreichbar und zeigten den englischen Fallback „Confirm“ aus `confirm_dialog_controller.js`. Prüffrage: Wird eine Rückfrage ohne confirmText erreichbar, prüfen, ob der Dialog lokalisiert ist.

- 20.10.2026, Fork 138 (DestroyJob-Fehler ins Debug-Log), Vor-PR-Review, behoben:
  - L8 (bekannte Art): Neues Logging in einem `rescue`, dessen Aufräumschritt (`update!` auf das Flag) selbst an einer Validierung scheitern kann; dann fliegt der Fehler aus dem rescue, Sidekiq wiederholt den Job und jeder Versuch loggt erneut. Prüffrage: Kann der Code innerhalb eines rescue selbst werfen (Validierung, gelöschter/gefrorener Datensatz)? Rücksetz-Flags wie im Vorbild per `update_column`.
  - L21 (bekannte Art): `DestroyableLater#restore_scheduled_for_deletion` löste dasselbe Problem schon mit `update_column`. Prüffrage: Gibt es für denselben Zustand bereits eine Rücksetz-Methode, deren Begründungskommentar auch hier gilt?
  - L29 (neu sichtbar): DebugLogEntry mit `account:` für einen schon gelöschten Datensatz verletzt den FK und `capture` verwirft den Eintrag still. Prüffrage: Kann der zu verknüpfende Datensatz beim Loggen schon weg sein (`destroyed?`)?

- 20.10.2026, Fork 139 (Super-Admin setzt Marktdaten instanzweit zurück), Vor-PR-Review, behoben:
  - L1/L2 (neu sichtbar): `Security::Price.delete_all` hätte auch Preise von Offline-Wertpapieren gelöscht, die weder `MarketDataImporter` noch Konto-Syncs je neu laden (`Security.online`). Prüffrage: Wer löscht geteilte Daten zum Neuladen, prüft, ob jeder gelöschte Datensatz einen Weg zurück hat (Offline-, manuelle, Custom-Einträge ausnehmen).
  - L8 (bekannte Art): Ein gemeinsames rescue um `import_all` hätte bei einem Fehler im Preis-Import auch den Kurs-Import übersprungen. Prüffrage: Unabhängige Schritte einzeln abfangen; und ein Job, der erst löscht und dann lädt, darf nach dem Löschen nicht wiederholbar scheitern (sonst löscht der Retry erneut).
  - L4 (bekannte Art): Instanzweiter Lösch-Job ohne Sperre gegen doppeltes Auslösen. Prüffrage: Kann derselbe zerstörerische Job zweimal parallel laufen (`sidekiq_options lock: :until_executed`)?
  - L13 (bekannte Art): Hinweistext versprach „alle Wertpapierpreise“, nach dem Fix bleiben Offline-Preise. Prüffrage: Nach jedem Review-Fix die UI-Texte gegen das neue Verhalten lesen.

- 20.10.2026, Fork 140 (Datencache leeren nur für die eigene Familie, Issue 92), Vor-PR-Review, behoben:
  - L14 (neu sichtbar): Ein `clear_cache`-Import je Konto überspringt die „schon vorhanden“-Prüfung, also wird ein Wertpapier oder Währungspaar, das k Konten teilen, k-mal voll beim Provider geholt (Kontingent). Prüffrage: Wird ein Import mit clear_cache/force in einer Schleife über Konten aufgerufen? Dann Fenster je Wertpapier/Paar zusammenführen und einmal holen.
  - L10 (neu sichtbar): `ExchangeRate::Importer` bevorzugte unter `clear_cache` an Tagen ohne Provider-Kurs (Wochenende) den alten DB-Kurs, `Security::Price::Importer` dagegen den Provider. Prüffrage: Wer „überschreiben statt löschen“ einführt, prüft, ob die Lückenfüllung alte Werte stehen lässt.
  - L7 (bekannte Art): Bestehender Controller-Test prüfte noch das alte Löschverhalten. Prüffrage: Bei Verhaltensänderung eines Jobs nach allen Tests suchen, die ihn über `perform_enqueued_jobs` mitlaufen lassen.
  - L11/L13 (bekannte Art): Nur en/de angepasst, 17 Sprachen beschrieben weiter das alte instanzweite Löschen. Prüffrage: Ändert sich die Bedeutung eines Textes, alle Locales nachziehen, nicht nur neue Keys.

- 20.10.2026, Fork 142 (Vorzeichen beim Reimport des eigenen CSV-Exports, upstream Issue 1092), Vor-PR-Review, behoben:
  - L2 (bekannte Art): Die Erkennung lief nur im Upload-Schritt. Das Drag-and-drop auf der Buchungsliste (`ImportsController#create`) legt den Import direkt an, und „Vorlage übernehmen“ (`apply_template!`) kopierte das Vorzeichen eines älteren Bank-Imports zurück. Prüffrage: Wer eine Import-Voreinstellung setzt, sucht alle Stellen, die `raw_file_str` schreiben oder Einstellungen kopieren (Upload, Drop-Zone, Vorlage, API).
  - L1 (bekannte Art): Bei erkanntem Sure-Export blieben Datums- und Zahlenformat auf den Familienwerten, bei deutschen Einstellungen scheitert der Rundweg trotzdem. Prüffrage: Ist ein Format eindeutig erkannt, alle festen Eigenschaften dieses Formats vorbelegen, nicht nur die gemeldete.
  - L7 (bekannte Art): Der Integrationstest reichte das gespeicherte Vorzeichen selbst zurück, statt zu prüfen, was das Formular vorauswählt. Prüffrage: Bei Voreinstellungen den gerenderten Wert prüfen (`option[selected]`).
  - L1 (neu sichtbar): Beim Ersetzen der Datei wurde die alte Kopfzeile mit dem neuen Trennzeichen gelesen. Prüffrage: Vergleiche mit dem alten Zustand nutzen alle alten Werte (`*_was`), nicht eine Mischung.

- 20.10.2026, Fork 144 (Zeitzonen-Dropdown, upstream Issue 325), Vor-PR-Review, behoben:
  - L1 (bekannte Art): Der Wechsel vom nativen Select auf `DS::Select` schickt bei fehlender Zeitzone ein leeres verstecktes Feld. Gespeichert würde `""`, und `in_time_zone("")` wirft in den Provider-Importen. Prüffrage: Wird ein Formularfeld auf ein anderes Bauteil umgestellt, prüfen, was es im leeren Zustand absendet, und leere Strings im Modell auf nil normalisieren.
  - L7 (bekannte Art): Eine Assertion suchte „St. Petersburg“ in Optionen, die es nach dem Fix gar nicht mehr gibt, und konnte nie rot werden. Prüffrage: Jede negative Assertion einmal gegen den alten Code laufen lassen.
  - L1/L14 (neu sichtbar): Listen aus Systemdaten (tzdata) unterscheiden sich je Host: alte Alias-Namen (Europe/Kiev und Europe/Kyiv) tauchten doppelt auf, und die Liste wurde bei jedem Aufruf neu gebaut. Prüffrage: Listen aus Host-Daten einmal pro Prozess bauen und mit dem Datenstand der CI testen. Nachtrag nach roter CI: TZInfo erkennt Alias-Namen aus Zonendateien nicht (`canonical_identifier` ist dort immer der Name selbst), deshalb Umbenennungen ausdrücklich zuordnen.
- 20.10.2026, Fork 141 (Kurs-Sperre pro Währungspaar), beim Bauen und in der CI behoben:
  - L4 (neu sichtbar): Eine wiederholte Sperrabfrage (`SELECT pg_try_advisory_lock(...)`) wird in Jobs vom ActiveRecord-Query-Cache beantwortet. Der wartende Job sah dadurch nie, dass die Sperre frei wurde. Prüffrage: Jede wiederholte Zustandsabfrage per SELECT (Sperren, Polling) in `uncached { }` ausführen und mit einem Test prüfen, der die Freigabe während des Wartens simuliert.
  - L7 (bekannte Art): Eine Test-Hilfsverbindung las `:user` aus der DB-Konfiguration, Rails nennt den Schlüssel `:username`. Lokal half PGUSER, in der CI (DATABASE_URL) schlug die Anmeldung fehl. Prüffrage: Tests mit eigener DB-Verbindung auch mit DATABASE_URL statt Einzel-ENV laufen lassen.
- 20.10.2026, Fork 146 (saubere Upstream-Kopie von Fork 92, Dashboard auf sortable-list), im Review max vor dem Upstream-PR behoben:
  - L7 (bekannte Art): Die Assertion „kein Speichern“ las den Antwortstatus direkt nach den Events. Ein fälschlich gestarteter PATCH hätte da noch nicht geantwortet, der Test konnte nie rot werden. Prüffrage: Negative Assertions auf Netzwerk-Aufrufe zählen den Aufruf synchron beim Absenden, nicht die Antwort.
  - L14 (neu sichtbar): Beim Zusammenlegen zweier Drag-Controller wurde vor dem Messen (getBoundingClientRect) eine Klasse entfernt, das erzwingt bei jedem dragover/touchmove ein zusätzliches Layout. Prüffrage: In Event-Handlern mit hoher Frequenz erst messen, dann DOM/Klassen ändern.
- **20.10.2026, Fork 135 → Upstream-Branch feat/holding-price-source, Review vor Upstream-PR, behoben vor PR:** L10/L13: Eine Anzeige leitete aus einem Fehlergrund (`health_check_failed`) ab, dass ein Fallback-Anbieter das Papier bepreist; der Health-Check prüft aber auch reine Sync-Papiere, die nie Anbieterkurse hatten. Prüffrage: Belegt der Zustand, aus dem ich eine Herkunft ableite, wirklich diese Herkunft, oder nur, dass jemand es versucht hat? L12: Handgebaute dt/dd-Zeile statt `DS::DetailRow`, obwohl dessen Doku die Holding-Ansicht ausdrücklich nennt; vor jeder neuen Zeile in Drawer-Listen nach DS-Komponenten greppen. L11: Neue Keys in securities.* fehlten für nb/ro, weil dort keine securities-Datei existierte; Sprachen aus SUPPORTED_LOCALES prüfen, nicht nur vorhandene Dateien.

- 20.10.2026, upstream PR 4336 (Codex P2/P1): Daten-Migration las Werte seitenweise und schrieb per `update_all` nur nach id zurück → ein Sync dazwischen wäre überschrieben worden; `down` war No-op, sodass ein Rollback verschlüsselte Werte für alten Code unlesbar ließ. Fix: Update nur, solange der gelesene Wert noch steht (`AND col::text = ?`), `down` entschlüsselt zurück. Lektion L5 (Migrationen) und L4 (Nebenläufigkeit): Prüffrage „Kann zwischen Lesen und Schreiben einer Daten-Migration ein Sync schreiben? Ist der Rollback für die Vorversion lesbar?“
- 20.10.2026, Fork 71 → Upstream-Branch feat/sync-exclusion-note (Fork 148), Review max vor dem Upstream-PR, behoben vor PR:
  - L4 (bekannte Art, zum zweiten Mal nach upstream PR 4215): Neue Sync-Schreibwege sperrten entries und schrieben danach transactions, ein normaler Save geht umgekehrt (Deadlock). Prüffrage: Schreibt ein neuer Sync-Weg in eine zweite Tabelle, die Sperr-Reihenfolge eines normalen Saves nennen oder die zweite Tabelle gar nicht anfassen.
  - L21 (neu sichtbar): Eigener Vermerk-Schlüssel in der Provider-Spalte transactions.extra statt des vorhandenen DataEnrichment-Protokolls; Folge waren Sonderfälle in Regeln und Rohdaten-Anzeige, ein Callback und eine fremde Feld-Sperre (lock_saved_attributes! sperrte „extra“ nach dem Toggle). Prüffrage: Bevor eine Herkunft/„wer hat das gesetzt“ gespeichert wird, nach Enrichable/DataEnrichment greppen.
  - L4/L16 (bekannte Art): lock! lädt per find; ein inzwischen gelöschter Datensatz warf RecordNotFound und brach die Bereinigung des ganzen Kontos ab. Prüffrage: lock!/reload in Sync-Schleifen braucht ein RecordNotFound-Verhalten.
  - L7 (neu sichtbar): upsert_all mit update_only als Symbole (%i[... updated_at]) erzeugt in Rails 8.1 eine doppelte updated_at-Zuweisung (PG-Fehler). Prüffrage: update_only als Strings übergeben und jeden Upsert-Pfad mindestens einmal im Test durchlaufen.
  - L30 (bekannte Art): Eine neue Bedingung (Nutzer-Sperre) kam in die Bereinigung, aber nicht in die zwei Stellen, die dieselben Einträge zählen (SimpleFIN-Karte, Review-Zähler). Prüffrage: Bei geänderter Auswahl alle Stellen suchen, die dieselbe Menge zählen, und einen gemeinsamen Scope nutzen.
  - L12 (bekannte Art): Turbo-Antwort ersetzte den Bereich mit dem neuen Hinweis nicht; er blieb nach dem Umschalten stehen. Prüffrage: Für jedes neue Element im Drawer prüfen, welche turbo_stream-Antwort es nach einer Änderung aktualisiert.
- 20.10.2026, Fork #149 (EB Saldo-Tiebreak, Nachfolger Fork #44), /code-review max vor Upstream-Freigabe:
  - L27 (bekannte Art): Heuristik-Stufe „neuere Buchung gewinnt“ lief vor dem direkten Beleg (Kreditrahmen-Differenz) und galt selbst als Beleg; sie konnte den Dispo-Saldo verifizieren. Prüffrage: Bei gestuften Entscheidungen zuerst die Stufe, die den gemeldeten Fehler direkt belegt; jede Stufe, die als „verifiziert“ zählt, gegen den Ursprungsfehler durchspielen.
  - L1 (bekannte Art): Gleiche Beträge zweimal gemeldet galten als Gleichstand (Warnung je Sync, nie verifiziert). Prüffrage: Duplikate mit identischem Wert vor jeder Tiebreak-Logik herausnehmen.
  - L7 (bekannte Art): Ternär `same_type.one? ? stage : :fresher` nutzte `stage` nie (immer nil bei einem Eintrag); Review-Vorschlag eines Bots ungeprüft übernommen. Prüffrage: Jeden Zweig eines übernommenen Bot-Fixes mit einem Test belegen.
  - L30 (bekannte Art): Neue Pending-Filterung (booked_raw_transactions) ohne den später auf main ergänzten Karten-Vormerkungs-Filter (unidentified_hold?). Prüffrage: Nach jedem main-Merge eigene Kopien von Filterregeln mit den Originalstellen abgleichen.
  - L26 (bekannte Art): Gleichstand im OPBD wurde entschieden und geloggt, bevor die Frische-Prüfung ihn verwarf. Prüffrage: Seiteneffekte (Logs) erst nach der endgültigen Auswahl.
  - L29 (neu sichtbar): Verifizierungs-Flag am Provider-Konto statt am Anker; nach Neu-Verknüpfung vertraute es einem fremden Anker. Prüffrage: Flags, die einen Zustand eines anderen Objekts beschreiben, an dessen Lebenszyklus binden (oder Zeitstempel prüfen).
  - L8 (bekannte Art): Debug-Warnung bei jedem Sync ohne Änderungsprüfung. Prüffrage: Wiederkehrende Provider-Warnungen nur bei Änderung loggen (Muster Account::Syncer#report_anchor_dated_away_from_holdings).
  - L1 (bekannte Art, CodeRabbit auf Fork 148): Ein neuer JSONB-Filter (`NOT (locked_attributes ? 'excluded')`) auf einer nullable Spalte schließt NULL-Zeilen stillschweigend aus. Prüffrage: Bei jedem neuen Filter auf jsonb/nullable Spalten `COALESCE` oder NOT NULL prüfen; den geteilten Concern nur anfassen, wenn alle Aufrufer NULL auch in Ruby vertragen.
- 20.10.2026, Fork #54 (manuelle Kontosortierung, Umbau auf sortable-list), /code-review max vor Upstream-Freigabe:
  - L21 (bekannte Art): Dritte Kopie der Zieh-Logik, obwohl main inzwischen einen gemeinsamen Controller hat. Prüffrage: Vor dem Upstream-PR nach jedem main-Merge suchen, ob main für eigene Hilfs-Controller inzwischen eine gemeinsame Basis hat.
  - L12 (neu sichtbar): Sortiermodus schaltete nur `draggable` der Zeile, `dragstart` von Kind-Elementen (Logo-Bild, Textauswahl) blubberte trotzdem zum Zieh-Handler. Prüffrage: Bei Zieh-Handlern prüfen, ob `event.currentTarget.draggable` gilt; Bilder und Auswahl sind von sich aus ziehbar.
  - L4 (bekannte Art): Gespiegelte Listen (gleiche Gruppe in mehreren Tabs) hatten je eine eigene Speicher-Warteschlange; Speichern aus zwei Tabs konnte überholen. Prüffrage: Eine Warteschlange je Speicherziel (URL), nicht je Controller-Instanz.
  - L12 (neu sichtbar): Aktiv-Klasse (bg-surface-inset) verlor gegen bg-transparent der Outline-Variante (gleiche Spezifität, spätere Regel). Prüffrage: Zustandsklassen auf DS-Buttons per Varianten-Präfix (aria-pressed:) setzen und im gebauten CSS prüfen.
  - L12 (bekannte Art): Stimulus-Zustand (Sortiermodus) nicht in connect() zurückgesetzt; aus dem Turbo-Seitencache wiederhergestellte Seite zeigte Leiste ohne Griffe. Prüffrage: Inline gesetzte Zustände in connect() neu anwenden.
  - L11 (bekannte Art): Handgebauter Griff (span role=button) statt DS::Button wie in der Regelliste; Fokusring ohne Dunkelmodus. Prüffrage: Gleiche Bedienelemente wie in bestehenden Listen über dieselbe DS-Komponente.
- 20.10.2026, Fork 40 → Upstream-Branch claude/project-thread-2bmqc3 (Auto-Buchung + „Jetzt buchen“, ohne „Wiederholen“), /code-review max und /security-review vor dem Upstream-PR, behoben vor PR:
  - L2 (bekannte Art, security-review): Das Einschalten der Auto-Buchung eines Transfers prüfte Schreibrecht aufs Zielkonto, spätere Änderungen (Betrag, Rhythmus, Fortsetzen, Termin-Betrag/Snooze/Reopen) nur das Quellkonto. Ein Nutzer mit Nur-Lese-Freigabe aufs Ziel konnte so steuern, was nachts dort gebucht wird. Prüffrage: Schreibt ein Hintergrundjob später in ein Konto, braucht jede Aktion, die Inhalt oder Zeitpunkt dieser Buchung bestimmt, dasselbe Schreibrecht wie die Buchung selbst, nicht nur der Schalter.
  - L2/L29 (neu sichtbar): „Verwerfen“ löschte beide Beine eines Transfers, auch wenn der Transfer-Matcher die selbst gebuchte Einzelbuchung später mit einer fremden Kontobuchung gepaart hatte. Prüffrage: Beim Löschen „mitgehender“ Datensätze prüfen, ob sie wirklich vom eigenen Vorgang stammen, nicht nur heute verknüpft sind.
  - L4 (bekannte Art): Bestätigen/Verwerfen verzweigten vor dem Lock auf einem veränderlichen Flag (pending_review); ein zweiter Klick oder veralteter Tab lief in den Matcher-Pfad und machte aus der Auto-Buchung eine Nutzer-Zahlung bzw. eine Match-Ablehnung. Prüffrage: Zweige nach dem unveränderlichen Merkmal (source), Zustand erst unter dem Lock prüfen.
  - L10 (bekannte Art): Eignungsregeln standen dreifach (Modell-Validierung, Controller can_post_now?, Drawer-ERB) und liefen auseinander (Währung fehlte im Drawer, Nachtlauf prüfte Währung/Festbetrag nicht). Prüffrage: Eine Modell-Prädikat-Methode, die Validierung, Job und Ansicht gemeinsam nutzen.
  - L1 (neu sichtbar): Änderung am Konto (Währung) ändert keine Spalte der Serie, daher lief die Validierung nie; der Job buchte in falscher Währung. Prüffrage: Hängt eine Regel an Werten eines anderen Datensatzes, im Job zur Laufzeit erneut prüfen.
  - L8 (bekannte Art): Money::ConversionError aus Transfer::Creator wurde in „Jetzt buchen“ zum 500. Prüffrage: Jeder neue Klickpfad, der Fremdwährung umrechnet, braucht ein Verhalten ohne Kurs.
  - L30 (neu sichtbar): Die Review-Liste zeigte vorläufige Buchungen nur für Termine, die die Übersicht ohnehin listet (keine Einnahmen, Transfers, Vormonat); sie blieben unbestätigt. Prüffrage: Neue Einträge in eine bestehende Liste: Filter der Liste gegen alle Typen des neuen Eintrags durchspielen.
  - L13 (bekannte Art): Re-Generierung ließ gestempelte Termine als Waisen stehen, wenn sich der Rhythmus änderte (doppelte Fälligkeit). Prüffrage: Beim Schützen von Zeilen vor einem Neuaufbau prüfen, ob die geschützte Zeile im neuen Plan noch existiert; sonst Merkmal übertragen statt Zeile behalten.
  - L14 (bekannte Art): before_destroy-Abfrage für jede gelöschte Buchung, obwohl nur selbst gebuchte (idempotency_key „recurring-…“) betroffen sein können. Prüffrage: Callbacks auf Entry mit Bedingung, die ohne Query entscheidet.
  - L30 (bekannte Art, Codex auf upstream PR 4340): Das Aufräumen hing an einem after_save, aber der Rake-Task `simplefin:pending_restore` schließt per `update_all` wieder ein und überspringt Callbacks. Prüffrage: Hängt eine Folgeaktion an einem Callback, alle `update_all`/`update_columns`-Wege auf dieselbe Spalte suchen (auch lib/tasks).
- 20.10.2026, upstream PR 4341 (manuelle Kontosortierung), Reviews nach dem PR, behoben in 37bb4f367:
  - L1 (bekannte Art, CodeRabbit): Der Cache-Schlüssel der Konto-Seitenleiste enthielt die neue Sortier-Einstellung nicht; ein Wechsel der Sortierung zeigte bis zum 12h-Ablauf die alte Reihenfolge. Prüffrage: Bei jeder neuen Einstellung, die gecachtes HTML verändert, den Cache-Schlüssel des Fragments mitprüfen und einen Test schreiben, der den Schlüsselwechsel zeigt.
  - L12 (neu sichtbar, Codex): Ein Sync-Toast-Refresh (Turbo-Morph) verwarf eine per Tastatur gegriffene, noch nicht gespeicherte Verschiebung. Prüffrage: Hat ein Bedienelement einen Zwischenzustand, der erst beim Loslassen speichert, muss der Auto-Refresh ihn als Interaktion erkennen (hier `[aria-grabbed='true']` in `#userIsInteracting`).
  - L12 (Folgebefund, CodeRabbit auf 37bb4f367, behoben in 5d30308e6): Die Sperre prüfte nur, ob das fokussierte Element in der gegriffenen Zeile liegt; nach Fokuswechsel oder Touch-Ziehen (Fokus auf body) griff sie nicht. Prüffrage: Zustände, die ein Refresh schützen soll, im ganzen Dokument suchen, nicht über den Fokus.
- 20.10.2026, upstream PR 4339 (Kontonummern/IBANs maskieren), Reviews nach dem PR, behoben in 2ac7cfb9a, f3f326a5d, 6bcca33da:
  - L5 (neu sichtbar, Codex): Spalte im selben Release gelöscht, in dem der Code aufhört, sie zu schreiben; bei Rolling Deploy (Helm, Worker nach Web) schreiben alte Worker sie noch, Syncs scheitern. Prüffrage: Spalten-Drop immer zweistufig: erst ignored_columns + kein Schreiben, Drop erst im Folge-Release.
  - L14 (bekannte Art, Codex): Daten-Migration lud jede Provider-Tabelle komplett und fragte je Zeile die verknüpften Konten ab. Prüffrage: Backfills mit Keyset-Batches und Join statt Query pro Zeile.
  - L13 (bekannte Art, Codex): Maskierungsregel (Schlüssel-Erkennung, Fio-Bankcode) lag im TransactionsHelper, Akahu-Normalisierung dreifach in ERB. Prüffrage: Datenschutz-/Fachregeln in Model/PORO, View ruft nur eine Methode.
  - L4 (bekannte Art, CodeRabbit): Migration las notes und schrieb per id zurück; parallele Änderung oder Sperre dazwischen wäre überschrieben worden. Prüffrage: UPDATE nach SELECT in Migrationen mit dem gelesenen Wert und den Sperrbedingungen absichern.
  - L1 (bekannte Art, CodeRabbit): Regex für angehängte Mercury-Details erkannte jeden Hash-Text, nicht nur Mercurys details-Schlüssel. Prüffrage: Aufräum-Muster auf die bekannten Schlüssel des Fremdformats beschränken, Gegentest mit ähnlichem Fremdtext.
  - L10 (bekannte Art, CodeRabbit): dieselbe Akahu-Kontonummer maskierte in Notizen anders (Bindestriche entfernt) als in den Details. Prüffrage: Eine Maskierungsregel, alle Anzeigeorte über dieselbe Methode mit denselben Optionen.
  - L3 (bekannte Art, CodeRabbit): Namens-Bereinigung ersetzte die volle Nummer nur als generierte Endung; umbenannte Namen mit der Nummer an anderer Stelle blieben offen. Prüffrage: Bei Datenschutz-Bereinigungen nach dem sensiblen Wert selbst suchen, nicht nach dem Format, in dem er entstand.
- 20.10.2026, Fork #151 (sortable-list: Pinch, Text-Drag, Selbst-Drop, Offline-Speicherfehler), eigenes /code-review vor dem PR, behoben vor dem ersten Push:
  - L6 (bekannte Art): Rücksetzen der Reihenfolge per DOM-Verschiebung nahm dem gegriffenen Element den Fokus. Prüffrage: Nach jedem programmatischen Verschieben von DOM-Knoten prüfen, ob der Fokus noch dort ist, und ihn zurückgeben.
  - L6 (neu sichtbar): Gleicher Text in eine aria-live-Region gesetzt wird beim zweiten Mal nicht angesagt. Prüffrage: Live-Region erst leeren, Text im nächsten Frame setzen.
  - L6 (neu sichtbar): Pinch-Schutz nur am Element; ein zweiter Finger außerhalb lief am Handler vorbei. Prüffrage: Mehrfinger-Gesten über einen touchstart-Listener am document (capture, passive) erkennen, nicht nur am gebundenen Element.
  - L4 (bekannte Art): Fehler-Toast wurde je Fehlversuch gestapelt, Rücksetzen bewegte alle Karten (Charts verbinden sich neu). Prüffrage: Wiederholbare Fehlermeldung vorher entfernen; Rollback nur die Elemente bewegen, die falsch stehen; Speichern nur bei tatsächlich geänderter Reihenfolge.
- 20.10.2026, upstream 4344 (Codex P2, behoben in a30d96a):
  - L1 (bekannte Art): Anker-Stufe ließ Buchungen ohne verwertbares Datum still weg, statt sich zu enthalten; eine undatierte Abbuchung konnte den falschen Kandidaten bestätigen. Prüffrage: Bei Abgleich-Rechnungen führt jeder unbekannte Eingangswert (Datum, Betrag) zum Enthalten, nie zum Weglassen.
  - L10 (bekannte Art): Eigene Datumslogik (Date.parse) statt der Processor-Logik (Zeitzone der Familie); um Mitternacht abweichende Tage. Prüffrage: Dieselbe Größe (Buchungsdatum) über dieselbe Methode berechnen, notfalls die vorhandene als Klassenmethode herausziehen.
- 20.10.2026, Fork-PR „Speichern und Sperren atomar“ (Branch claude/project-thread-w6kkcd), eigenes /code-review max vor dem PR, behoben in 7a4887bd6:
  - L4 (bekannte Art): Ein Transaktions-Helper beendete den Block bei Fehlschlag mit `next false`; die äußere Transaktion committete, und das innere `update` (joined) konnte seinen Rollback nicht durchsetzen. Tags, die `tag_ids=` schon geschrieben hatte, blieben trotz 422 gespeichert. Prüffrage: Ein Helper, der fremde Saves in eine Transaktion legt, muss bei false `ActiveRecord::Rollback` werfen, nie nur einen Wert zurückgeben.
  - L4 (neu sichtbar): Neue Zeilensperren (FOR UPDATE) kehrten die Sperr-Reihenfolge um: Saves schreiben erst transactions, dann entries (has_one touch); der neue Weg sperrte erst entries. Ergebnis: echter Deadlock mit Regeln/KI-Kategorisierung. Prüffrage: Vor jeder neuen Zeilensperre die Reihenfolge der vorhandenen Schreibwege per SQL-Log ermitteln und dieselbe Reihenfolge nehmen; Race-Test mit zwei Verbindungen.
  - L1 (bekannte Art): `lock!` (reload) wirft RecordNotFound, wenn der Nutzer die Zeile zwischen Laden und Sperren löscht; im Sync bricht das den ganzen Stapel ab. Prüffrage: Jedes neue `lock!`/`reload` in Sync-Pfaden braucht ein Verhalten für „inzwischen gelöscht“.
  - L1 (neu sichtbar): `lock_saved_attributes!` liest `saved_changes`; jeder Save davor (Tags, `lock_attr!`) ersetzt sie. Bulk-Edit, API-Update und Assistant sperrten so die Kategorie nicht, wenn Tags mitgeändert wurden. Prüffrage: Zwischen Save und `lock_saved_attributes!` darf kein weiterer Save desselben Datensatzes liegen.
- 20.10.2026, upstream PR 4346 (Notiz-Aktionen), Codex P2, behoben in 2affeb90b und b126e19de:
  - L4 (bekannte Art): Anhängen las die Notizen, verglich und speicherte ohne Sperre; eine Bearbeitung dazwischen (auch mit Sperre der Notizen) wurde überschrieben. Prüffrage: Jedes Lesen-Ändern-Schreiben eines Feldes, das Personen parallel bearbeiten, unter Zeilensperre mit Reload.
  - L1 (neu sichtbar): `entry.with_lock` liefert auf Entry still nichts, weil `Entry#transaction` der Delegated-Type-Leser ist und den Block ignoriert; erst ein Test mit veraltetem Objekt zeigte es. Prüffrage: Auf Entry `Entry.transaction { entry.lock! … }` statt `with_lock`/`entry.transaction do`; jede neue Sperre mit einem Test belegen, der ohne sie rot ist. Zusätzlich `RecordNotFound` aus `lock!` abfangen (gelöscht seit dem Laden).
- 20.10.2026, upstream PR 4347 (Regeln sofort anwenden), Codex 1× P1, 2× P2, CodeRabbit 6× Minor, behoben in 2f9cfd929:
  - L2 (bekannte Art, Codex P1): Der Sofort-Lauf hing an „Update erfolgreich“, nicht an „etwas geändert“; ein Update, dessen Felder die Rechteprüfung komplett herausfilterte, startete trotzdem familienweite Regeln (KI, Transfers). Prüffrage: Folgeaktionen eines Edits an die tatsächliche Änderung koppeln (Snapshot vorher/nachher inkl. Tags aus der DB), nie an den Erfolg von `update`.
  - L10 (bekannte Art, CodeRabbit 6×): Jeder Auslöser (Web, Tags, Bulk, Kategorisieren, API, Assistent) prüfte „geändert“ anders oder gar nicht; `bulk_update!` liefert die Auswahlgröße, nicht die Zahl der Änderungen. Prüffrage: Eine gemeinsame Änderungsprüfung (`Entry#rule_input_snapshot`, Block von `bulk_update!`) für alle Wege.
  - L14 (bekannte Art, Codex P2): Die Einschränkung auf die geänderten IDs kam erst nach `matching_scope`, das Regex-Treffer schon familienweit auflöst. Prüffrage: Filter, die eine teure Auflösung begrenzen sollen, vor die Auflösung reichen (Parameter statt nachträgliches where).
  - L12 (bekannte Art, Codex P2): Der Toast kam sofort, auch wenn KI-Aktionen noch als Job liefen; Auto-Refresh zeigte das alte Ergebnis, später kam kein Hinweis. Prüffrage: Hinweise auf ein Ergebnis erst senden, wenn alle asynchronen Teile fertig sind (hier RuleRun#complete_job!).
  - L1 (Folgebefund, CodeRabbit Major auf 2f9cfd929, behoben in 649d127da): Der neue Toast-Broadcast lief in RuleRun#complete_job! innerhalb von AutoCategorizeJob; ein Fehler dort ließ den Job scheitern und die KI-Arbeit wiederholen. Prüffrage: Benachrichtigungen, die in fremden Jobs nach getaner Arbeit laufen, immer best-effort (rescue + Log).
- 20.10. (Fork 155 Händlerliste merkt Listenzustand, eigenes /code-review vor dem PR):
  - L1-Art (neu formuliert): Zustand, der bei GET in die Sitzung geschrieben und später per Redirect wiederholt wird, muss vor dem Speichern gültig sein. Eine Seitenzahl 0/„abc“ hätte Pagy::VariableError dauerhaft bei jedem Besuch ausgelöst. Prüffrage: Was passiert, wenn ein ungültiger Wert gespeichert und bei jedem Besuch wieder abgespielt wird?
  - Turbo-Prefetch (bekannte Art, vgl. InsightsController#prefetch_request?): GET-Seiteneffekte (Sitzung schreiben, Zähler) feuern schon beim Hover über Links. Prüffrage: Schreibt der GET etwas? Dann Prefetch-Anfragen (X-Sec-Purpose/Sec-Purpose) ausnehmen und testen.
- 20.10. (Fork 156 Regel-Aktion mit Provider-Händlern, eigenes /code-review vor dem PR):
  - L2/L6 (neue Art): Optionslisten, die auf den Betrachter gescopt sind (accessible_by), lassen einen gespeicherten Wert fehlen, den ein anderes Mitglied gesetzt hat. Das Select fällt still auf die erste Option zurück, und Speichern überschreibt den Wert. Prüffrage: Kann der gespeicherte Wert in der gescopten Liste fehlen? Dann den gespeicherten Wert anhängen (hier Rule::Action#options + ActionExecutor#option_for) oder bewusst ablehnen.
  - L14 (bekannte Art): Neue Optionsliste per pluck aller merchant_ids gebaut, die je Regel zweimal auf der Regelliste lief. Prüffrage: Listen, die pro Zeile einer Liste gebaut werden, als Subquery statt pluck + IN-Liste.
  - L2 (bekannte Art): Umwandeln/Zusammenführen von Händlern ließ Regeln auf die alte ID zeigen; der nächste Regellauf machte die Umwandlung rückgängig. Prüffrage: Wenn Datensätze umgehängt werden, auch Referenzen in Regeln (Bedingungen inkl. Untergruppen, Aktionen) mitziehen.
- 20.10. (Fork 157 Händler bei Split-Buchungen, eigenes /code-review vor dem PR):
  - L1 (Altdaten): Weitergabe vom Eltern- an Kind-Datensätze nur über „gesperrt“ zu entscheiden hätte bestehende, ungesperrte Abweichungen (Import, Regeln) überschrieben. Prüffrage: Gibt es Altdaten ohne die neue Markierung? Dann zusätzlich am alten Wert vergleichen (z. B. merchant_id_before_last_save) statt Backfill.
  - L14 (Callback-Kosten): Ein after_update auf einem häufig geänderten Feld lief für jede Transaktion mit Entry-Load plus Kinder-Abfrage. Prüffrage: Wie oft feuert der Callback (Regeln, Sync, Bulk)? Auf eine Abfrage reduzieren.
  - L14 (teure Prüfmenge): Zum Prüfen weniger IDs nicht family.available_merchants_for (scannt alle Transaktionen) nehmen, sondern die kleinste gültige Menge (Merchants der eigenen Kinder + Familien-Merchants).
  - L6 (Turbo): Ändert eine Aktion per Callback auch andere sichtbare Zeilen, müssen deren Zeilen im turbo_stream mit ersetzt werden.
- 21.10.2026 (PR-Check, Review neuer Heads, behoben in res-Ständen):
  - L17/L3 (neu sichtbar, upstream 4344): Duplikatsperre las `metadata->>'fingerprint'` direkt in SQL; der offene eigene PR 3833 verschlüsselt `DebugLogEntry.metadata`, danach liefert die SQL-Abfrage NULL und die Sperre greift nie. Kein Textkonflikt, nur ein Widerspruch zwischen zwei eigenen PRs. Prüffrage: Liest der Diff ein Feld per SQL (jsonb-Operator, where auf Wert), das ein anderer offener PR verschlüsselt? Dann über das Modell lesen.
  - L26 (bekannte Art, upstream 4341): Manuelle Sortierung mit Name als letztem Schlüssel; gleichnamige Konten ohne Position sprangen, weil die Eingabe kein ORDER BY hat. Prüffrage: Jede Sortierung endet auf einem eindeutigen Schlüssel (id).
  - L11 (bekannte Art, upstream 4184): `data-turbo-confirm` als Hash ohne `confirmText` zeigt den hart codierten Knopf „Confirm“ in jeder Sprache. Prüffrage: Bestätigungen über `CustomConfirm.new(...).to_data_attribute` bauen.
  - L11 (bekannte Art, upstream 4340): Neue Keys nur in en/de, obwohl die Nachbar-Keys desselben Abschnitts in 14 Sprachen übersetzt sind; der Hinweis erschien englisch direkt unter übersetztem Text. Prüffrage: Neue Keys in jede Locale, die den Nachbar-Key schon hat.
- 21.10. (Fork 156, CodeRabbit auf 6ec888a, behoben in a83b7ae):
  - L1 (bekannte Art, Major): Export schrieb Provider-Händler in Regeln mit value_ref, der Import löste sie aber nur per Name über family.merchants auf und legte einen neuen FamilyMerchant an; die Buchungen zeigten auf den wiederverwendeten ProviderMerchant. Prüffrage: Löst der Import Referenzen über dieselbe ID-Zuordnung (id_mappings) auf wie die Datensätze, auf die sie zeigen?
  - L2 (Folgebefund, Minor): Der Fix für das Regel-Formular (gespeicherten Händler behalten) fehlte im KI-Regelwerkzeug; Ersetzen der Aktionen lehnte den gespeicherten Händler ab. Prüffrage: Wenn ein Weg für gescopte Optionen repariert wird, alle anderen Wege mit derselben Validierung (Assistant/MCP, API, Import) mitziehen.
- 21.10. (Fork 154, Claude-Review auf f002b47, behoben in 1d29cac):
  - L4 (bekannte Art, Unique-Kollision): Beim Zusammenführen kollidierender Positionen wurde die external_id der Quellzeile auf die Zielzeile kopiert, bevor die Quellzeile gelöscht war; der Unique-Index (account_id, external_id) lehnte das ab (vorher RecordInvalid, nach dem Wechsel auf update_columns RecordNotUnique). Prüffrage: Wird ein eindeutiger Wert von Zeile A auf Zeile B übertragen, die A ersetzt, erst A löschen, dann B schreiben.
- 21.10. (Fork 150, Claude-Review auf c0ee7c5 und /code-review max, behoben in e28a726):
  - L2 (bekannte Art): Die Zielkonto-Prüfung für auto-buchende Transfers stand nur in den Web-Pfaden; PATCH /api/v1/recurring_transactions/:id und das Assistent-Werkzeug update_bill prüften nur das eigene Konto. Prüffrage: Neue Rechte-Regel als Modell-Prädikat bauen und per grep alle Wege (Web, API, Assistant/MCP) darauf umstellen.
  - L10/L2 (neue Art, Doppelbuchung): Der nächtliche Poster mied nur Termine mit vorhandener Zuordnung, aber die Zuordnung „Buchung von Hand ↔ Termin“ macht der Matcher, der bei Familien ohne Bank-Sync im Nachtjob nie lief. Prüffrage: Hängt ein Schutz an Daten, die ein anderer Prozess erzeugt? Dann prüfen, ob dieser Prozess auf jedem Weg vorher läuft.
  - L4 (bekannte Art): Unter der Termin-Sperre wurden Schalter und verschobenes Fälligkeitsdatum nicht neu geprüft; eine Pause oder ein Snooze während des Laufs wurde überbucht. Prüffrage: Nach lock! alle Bedingungen erneut prüfen, die vor der Sperre gelesen wurden, und abgeleitete Werte (Datum) erst danach berechnen.
  - L8 (bekannte Art): Ein neuer familienweiter Schritt (Matcher) stand außerhalb des per-Serie-rescue; ein Fehler hätte alle Serien gestoppt, ohne DebugLogEntry. Prüffrage: Steht ein neuer Schritt außerhalb vorhandener Fehlergrenzen, eigene Grenze mit DebugLogEntry.capture und sicherem Ausgang.
  - L2 (Folgebefund, /security-review, behoben in Folge-Commit): Zahlung entfernen und Vorschlag ablehnen öffnen den Termin ebenfalls wieder, prüften aber das Zielkonto nicht, anders als reopen/snooze. Prüffrage: Bei einer Regel „wer X auslöst, braucht Recht Y“ alle Aktionen suchen, die X indirekt auslösen (hier: Termin wieder öffnen).
- 21.10. (upstream 4339 Maskierung, jjmata + PR-Check + eigenes /code-review, behoben in 0e0c695de bis a925a76f5):
  - L3 (neue Art, Maskierung): „Alles unter einem Nummern-Schlüssel maskieren“ hat Namen und Kartenmarken unlesbar gemacht; die erste Korrektur (nur number/no/value maskieren) hätte Nummern unter anderen Keys oder eine Ebene tiefer offengelegt. Prüffrage: Beim Lockern einer Maskierung Standard „maskieren“ beibehalten und nur bekannte beschreibende Felder freigeben (Allowlist), mit Test für beide Richtungen.
  - L5/L10 (bekannte Art, Daten-Migration): `gsub(identifier, …)` ohne Wortgrenze verändert längere Zahlen, die die Nummer enthalten. Prüffrage: Ersetzungen in Bestandsdaten immer verankern (`(?<![[:alnum:]])…(?![[:alnum:]])`) und einen Test mit „enthält die Nummer“ schreiben.
  - L1 (Altdaten): Neue Importe maskierten Akahu-Notizen, der Bestand nicht (für Mercury gab es eine Migration). Prüffrage: Ändert ein PR, was ein Import in Freitext schreibt, braucht jeder Anbieter eine Bestands-Migration oder eine begründete Ausnahme. Den Wert dafür aus den gespeicherten Rohdaten nehmen (hier extra.akahu.other_account) statt per Regex zu raten.
- **21.10.2026, upstream PR 4338 (Sparklines), Maintainer-Frage, Owner-Vorgabe:** neue Lektion L34 (Funktion vorher auf main und nachher sichtbar prüfen). L7 geschärft: Ein Systemtest für ein Diagramm prüft das gezeichnete Element (`svg path`), nicht nur geladenes Markup.
- **21.10.2026, Fork PR 160 (Rückfrage bei Entsperren/Zurücksetzen im Holding-Drawer), /code-review high:** L6-Prüffrage aus upstream 4184 hat gegriffen: zwei weitere `turbo_confirm` auf `data-turbo=false`-Formularen in holdings/show (Unlock, Reset to provider), Aktion lief ohne Dialog. Behoben mit `turbo_frame: "_top"` + `CustomConfirm`. Neu (L7, Tests): `Account.any_instance.stubs(:linked?)` im Systemtest gilt für jedes Konto und verändert auch die Seite nach dem Redirect; stattdessen echten Zustand herstellen (Plaid-Fixture am Konto). Prüffrage: Stubbt ein Systemtest per any_instance mehr als den einen Datensatz, den er meint? Geprüft und verworfen: Same-URL-Redirect mit Morph lässt die Holdings-Liste nicht veralten (im Browser nachgesehen).
- 21.10. (upstream PR 4347 Sofort-Regeln, PR-Check 21.10. und /code-review max, behoben in e910027fc und 111d2855f):
  - L2 (neue Art, veraltete Formularwerte): Das Transaktionsfenster schickte beim Speichern eines Feldes alle Felder desselben Formulars mit; Werte, die eine Regel im Hintergrund gesetzt hatte (Kategorie, Name, Tags), wurden mit dem alten Stand überschrieben und gesperrt. Ebenso schickte die Tag-Auswahl die volle Menge. Prüffrage: Kann ein Hintergrundprozess (Job, Regel, Sync) Felder ändern, während ein Auto-Speichern-Formular offen ist? Dann je änderbares Feld ein eigenes Formular oder nur die Differenz senden; Textfelder auf „change“ statt „blur“.
  - L13 (bekannte Art): Der UI-Text versprach Sofort-Regeln für jede Änderung, obwohl Aufteilen, Überweisungen und Trade-Umwandlung nicht angeschlossen waren. Prüffrage: Jede Aufzählung im UI-Text gegen die Liste der tatsächlich angeschlossenen Wege prüfen.
  - L5 (bekannte Art): Migration älter datiert als die neueste main-Migration, Schema-Version nicht hochgezählt. Prüffrage: Vor jedem Upstream-Push den Zeitstempel gegen main prüfen.
- 21.10. (Fork 150, /code-review max auf c0ee7c5 und auf die eigene Runde 3, behoben in a2326cc..HEAD):
  - L31 (Zeitbezug, bekannte Art): „Zeile vor Fälligkeit angelegt“ verglich `created_at::date` (UTC) mit dem lokalen Fälligkeitsdatum; östlich von UTC doppelte Buchung, westlich fälschlich zurückgehalten. Prüffrage: Jeder Vergleich Zeitstempel ↔ Kalenderdatum in der Zeitzone der Familie.
  - L21 (Ursache statt Symptom): Die erste Regel gegen Doppelbuchung nach Planänderung (nur „nachträglich angelegt“) traf den Hauptfall (Tag innerhalb eines schon gebuchten Monats verschoben) nicht. Prüffrage: Den vom Nutzer beschriebenen Fall als Test nachstellen, nicht nur die Variante aus dem Befund.
  - L1 (bekannte Art): Beim Behalten statt Neuanlegen von Zeilen (gebuchte Termine beim Neuaufbau) blieben abgeleitete Spalten (Währung) alt, und „beendet“ wurde wie „pausiert“ behandelt. Prüffrage: Wer eine Zeile behält statt neu zu bauen, setzt alle Spalten, die der Neubau gesetzt hätte, und unterscheidet jeden Status.
  - L1 (Export/Import): Schutz hing an einem Schlüssel (idempotency_key) und einem Stempel (auto_posted_at), die der Export nicht mitnimmt. Prüffrage: Hängt eine Regel an Spalten, die Export/Import verliert? Dann an die mitexportierte Spalte binden oder beim Import setzen.
  - L8: `params[:x].present?` als Boolean; `x=0` zählte als wahr. Prüffrage: Boolean-Parameter mit ActiveModel::Type::Boolean casten.
  - L2 (Folgebefund /security-review, behoben in b112c2e): Überspringen und „bezahlt“ eines Termins verhindern die Buchung ins Zielkonto, prüften das Zielkonto aber nicht (Owner: auch Pausieren wirkt aufs Zielkonto). Prüffrage: Zählt bei „wer X beeinflusst“ auch das Verhindern von X? Dann gleiche Prüfung.
- 21.10. (Fork Regel-Gruppen, Branch claude/project-thread-yqdxpg, /code-review max auf 2a851b6, behoben in 7b273c5):
  - L1 (neue Art, CSV): Ruby-CSV füllt bei Zeilen mit mehr Feldern als Kopfzeilen die Header mit nil auf; der Index „vom Ende gezählt“ (group_index - headers.size) traf dann das falsche Feld. Prüffrage: Positionsrechnung über CSV-Felder gegen `headers.compact.size` und mit einem Test für eine aufgespaltene Altzeile.
  - L2 (bekannte Art, verschluckte Fehler): Ein über ein Formularfeld neu gebautes Objekt (Gruppe aus „neue Gruppe“) wurde bei ungültigem Namen still verworfen. Prüffrage: Fehler eines nebenbei gebauten Datensatzes auf das Formularfeld kopieren.
  - L8 (bekannte Art): Eine fremde oder nicht existierende ID in einem belongs_to-Parameter lief auf den Fremdschlüssel (500). Prüffrage: `x_id.present? && x.nil?` als Validierungsfehler melden.
  - L4 (bekannte Art, Unique-Rennen): find_or_create_by! auf eindeutigem Namen im Import; Formularweg ohne Rettung bei RecordNotUnique. Prüffrage: `find_by || create_or_find_by!` und im Controller einmal neu speichern.
  - L10 (neue Art, Laufzeit): Jede Gruppenänderung schrieb alle Positionen neu (normalize!); ein Import mit vielen Regeln wurde quadratisch. Prüffrage: Positionen lokal verschieben (nur Einträge nach der Einfügestelle +1).
  - L11/L13 (bekannte Art): Suche ließ Freitext-Aktionen weg (Optionen nil vs. leer verwechselt); Modellnamen und Attribute ohne Übersetzung.
  - DS (bekannte Art): Handgebaute select_tag-Filter und Klappgruppe statt DS::Select und DS::Disclosure. Prüffrage: Vor jedem Formular-Element und Aufklapp-Muster app/components/DS durchsehen.
  - L1 (Daten): „Alle Regeln löschen“ ließ leere Gruppen zurück. Prüffrage: Massenlöschen auf neue abhängige Tabellen erweitern.
- 21.10.2026, upstream PR 3098 (Marktdaten-Zeitplan), Maintainer-Review jjmata, behoben:
  - L8 (bekannte Art): Fehler des neuen Marktdaten-Zeitplans (Speichern in den Einstellungen, Cron-Job beim Sidekiq-Start) landeten nur im Rails-Log. Prüffrage: Führt der Diff neue Fehlerpfade ein, die erklären, warum Kurse/Syncs ausbleiben? Dann zusätzlich DebugLogEntry.capture. Ein Logging-Helfer, der in rescue-Blöcken (v. a. Startup-Hooks) läuft, darf selbst nie werfen, auch nicht beim Zusammenbauen der Metadaten (Setting-Lesen vor dem capture-Rescue).
- 21.10.2026, upstream PR 4418 (Rückfragen im Holding-Drawer), Codex P1, behoben in b8e196d:
  - DS (bekannte Art): Der Diff fasste zwei handgebaute button_to-Knöpfe an (nur Formular-Attribut und Bestätigung), stellte sie aber nicht auf DS::Button um. Codex bewertet das upstream mit Verweis auf AGENTS.md als P1. Prüffrage: Ändert der Diff Zeilen in einem handgebauten Knopf, Dialog oder Badge, wird er auf die DS-Komponente umgestellt, auch wenn er vorher schon so war, samt gleichartiger Nachbarn im selben Block. „Minimaler Diff“ ist dafür kein Grund.
- 21.10.2026, upstream PR 3502 (Rechenleiste am Betragsfeld), Owner-Bugmeldung, behoben in 79ea55fa0:
  - DS/CSS (neue Art): `group-focus-within:` ohne Namen trifft jede `.group`-Vorfahrin; jede DS::Disclosure (jede DS::Dialog-Sektion) ist eine, daher erschien die Leiste beim Fokus auf den Namen. Prüffrage: Jede `group-*`-Variante in einer Partial/Komponente, die in fremden Containern landet, braucht eine benannte Gruppe (`group/name` + `group-*/name:`); Systemtest mit Fokus auf ein Nachbarfeld im Drawer. Nebenbefund: Ein per `display:none` verstecktes Element, das erst durch den Fokus sichtbar wird, ist per Tab nicht erreichbar, wenn zwischen Blur und Fokus kein Element der Gruppe fokussiert ist.
- 21.10.2026, IBAN-Serie (upstream PR 3510, feat/iban-foundation) und Verfügbarkeit (upstream PR 4017, feat/account-availability), Owner-Bugmeldung:
  - L13 (neue Art, Felder je Kontotyp): Ein neues Feld im gemeinsamen Formular `accounts/_form` erschien bei jedem Kontotyp, der dieses Formular nutzt: IBAN auch bei Fahrzeug, Sonstiges, Krypto und Bargeld; Verfügbarkeit beim Fahrzeug, aber nicht bei der Immobilie, weil die ein eigenes Reiter-Formular hat (Zufall statt Absicht). Prüffrage: Kommt ein Feld in `accounts/_form` (oder ein Parameter in `AccountableResource#account_params`), für jeden der Typen in `Accountable::TYPES` beantworten, ob es dort Sinn ergibt. Die Regel als Klassenmethode am Accountable ablegen (z. B. `supports_iban?`), nicht im ERB, und den Parameter für Typen ohne das Feld auch serverseitig verwerfen. Typen mit eigenem Formular (Immobilie) gesondert prüfen, damit Verhalten nicht zufällig auseinanderläuft.
- 21.10.2026, Kontogruppierung (upstream PR 4018, Branch feat/account-subgroups, Fork 53), zwei Owner-Bugmeldungen:
  - L13 (bekannte Art, Felder je Kontotyp, Gegenstück auf der Leseseite): Die Gruppierung nach Unterart oder Steuerart steckte Fahrzeug, Kreditkarte und Sonstiges in „Ohne Angabe“, obwohl deren Formular das Feld gar nicht anbietet; „Ohne Angabe“ verlangte also einen Wert, den man nicht eintragen kann. Zusätzlich zeigte die Regel „Ebene 2 immer anzeigen“ unter „Fahrzeug“ eine einzelne Zeile „Ohne Angabe“. Prüffrage: Gruppiert, filtert oder summiert der Diff nach einem Feld, für jeden Typ in `Accountable::TYPES` klären, ob das Feld dort existiert; „nicht vorhanden“ anders behandeln als „leer“ (hier: Kontotyp als Wert, doppelte Zwischenzeile weglassen). Auch abgeleitete Werte prüfen (Kreditkarte mit Anbieter-Unterart, HSA-Steuerart), damit nicht zwei gleichnamige Gruppen entstehen. Ersatzschlüssel als eigene Klasse, nicht als String-Präfix, damit kein Freitext ihn trifft.
  - L2/L13 (bekannte Art, Typen mit eigenem Formular): Das neue Feld „Eigene Gruppe“ stand nur in `accounts/_form`; die Immobilie nutzt beim Anlegen und Bearbeiten ein eigenes Reiter-Formular (`properties/_overview_fields`), dort fehlte es, obwohl der Controller den Parameter erlaubte. Prüffrage: Für jedes neue Kontofeld alle Formulare aufzählen (grep auf `accounts/form` und auf `styled_form_with model: @account`), Felder als gemeinsame Partial einbinden statt kopieren, und je Sonderformular einen Controller-Test, der das Feld im Formular findet.
- 22.10.2026, upstream PR 4339 (fix/encrypt-remaining-provider-identifiers), PR-Check-Review, behoben in ca6923a24:
  - L4/L5 (bekannte Art, Daten-Migrationen): Zwei Notiz-Migrationen arbeiten in Stapeln, liefen aber ohne `disable_ddl_transaction!` als eine Transaktion; ein Abbruch spät im Lauf verwarf alle schon maskierten Stapel und hielt Sperren bis zum Ende. Prüffrage: Jede Daten-Migration mit `in_batches`/`find_each` bekommt `disable_ddl_transaction!` und ist wiederholbar (idempotent).
  - L4 (bekannte Art, Lost Update): Die Migration, die Kontonummern aus Kontonamen maskiert, schrieb per UPDATE den berechneten Namen, ohne zu prüfen, ob der Name seit dem Lesen geändert wurde. Prüffrage: Ein UPDATE, das einen aus dem gelesenen Wert berechneten Wert schreibt, hat den gelesenen Wert in der WHERE-Bedingung.
- 22.10. (upstream PR 4347, PR-Check 22.10., behoben in Folge-Commit „Queue drawer tag saves“):
  - L4 (bekannte Art, Race): Die Tag-Auswahl brach die vorige Speicher-Anfrage per AbortController ab; der Server hatte sie aber oft schon angewendet, und die nächste Anfrage rechnete die Differenz gegen den alten Stand. Prüffrage: Wer Anfragen clientseitig abbricht, darf nicht annehmen, dass der Server sie nicht ausgeführt hat; bei Differenz-Protokollen Anfragen verketten statt abbrechen.
  - L13 (bekannte Art): UI-Text angepasst, die gleiche Beschreibung in swagger_helper/openapi.yaml nicht. Prüffrage: Bei Textänderungen nach dem alten Wortlaut in spec/ und docs/ greppen.
- 22.10.2026, upstream PR 3510 (IBAN-Basis), PR-Check 22.10., behoben in Folge-Commit auf feat/iban-foundation:
  - L3 (neue Art, Verschlüsselung umgangen): Die Enable-Banking-Übernahme schrieb die verschlüsselte Spalte accounts.iban über `enrich_attribute`; das protokolliert den Wert zusätzlich im Klartext in data_enrichments. Prüffrage: Wird ein verschlüsseltes Attribut über enrich_attribute(s), Audit-Logs, DebugLogEntry, Fehlermeldungen oder Exporte geschrieben? Dann einen Weg ohne Klartext-Kopie wählen und per Test prüfen, dass keine Protokollzeile entsteht; Altdaten in Protokolltabellen bedenken.
  - L2 (bekannte Art): Die neue Typ-Regel (supports_iban?) stand im Formular, aber nicht in Sync und Import; der Import zählte eine belegte IBAN bei Typen ohne IBAN als „skipped“. Prüffrage: Neue Typ-Regel per grep in allen Schreibwegen (Formular, API, Sync, Import) anwenden.
- 22.10.2026, upstream PR 4018 (Kontountergruppen), PR-Check-Befund auf fad52d4e0, behoben in 116065950:
  - L13 (bekannte Art): Eine Ersatz-Typgruppe (Ebene 1 Steuerart, Konto ohne Merkmal → „Fahrzeug“) mit Ebene 2 = Kontotyp zeigte eine Unterzeile, die den Gruppennamen wiederholt. Prüffrage: Bei Kombinationen von Ebenen auch die Ersatzgruppen durchspielen, nicht nur die regulären Werte.
- 22.10.2026, upstream PR 4191 (claude/project-thread-fbf35j), CodeRabbit Minor, behoben in c6c088046:
  - L2 (bekannte Art, Nebenwirkung ohne Änderung): Der Passwort-Reset beendete alle Sitzungen auch dann, wenn ein leeres Passwort gespeichert wurde und sich der Digest nicht änderte. Prüffrage: Hängt eine Nebenwirkung (Abmelden, Token widerrufen) an „Speichern erfolgreich“, prüfen, ob sich der auslösende Wert wirklich geändert hat (`saved_change_to_<attr>?`), wie es die Modell-Callbacks schon tun.
- 22.10.2026, upstream PR 4336 (fix/encrypt-remaining-provider-identifiers), CodeRabbit, behoben in 76a4fdecd:
  - L4 (bekannte Art, Lost Update): Der Verschlüsselungs-Backfill las eine Zeile und schrieb sie per update_columns zurück; ein App-Schreibzugriff dazwischen (neue last_psu_ip, DataCleanerJob löscht sie) wurde mit dem alten Wert überschrieben. Prüffrage: Ein Task, der Zeilen liest, umrechnet und zurückschreibt, liest und schreibt unter `with_lock` oder mit dem gelesenen Wert in der WHERE-Bedingung; Test mit einer Änderung zwischen Laden und Schreiben.
  - L1 (bekannte Art, CodeRabbit Major auf 8dba5cc51, behoben in a4542ce90): AccountSubgroup#total filterte nur exclude_from_reports, nicht included_in_finances?; Untergruppen-Summen ergaben nicht die Gruppensumme. Prüffrage: Neue Summen-Ebenen immer über denselben Zähl-Helper (ClassificationGroup.counted_accounts) wie die Ebene darüber, plus Test „Teilsummen = Summe“ mit geteiltem, nicht einbezogenem Konto.
- 22.10.2026, Fork PR 165 (claude/project-thread-g9cakl, Gruppen-Sparklines), /code-review vor dem PR, behoben vor dem ersten Push:
  - L1 (Datenrandfall große Mengen; Client bestimmt die Menge): Erste Fassung schickte die Konto-IDs der Gruppe in der URL; Folgen: URL-Längengrenze bei großen Gruppen, stille 500er-Kappung (Linie ≠ Summe), doppelte Frame-IDs über Tabs/Mobil. Prüffrage: Lazy-Frames für berechnete Gruppen schicken nur Schlüssel und bauen die Menge serverseitig mit demselben Helper wie die Ansicht nach; Frame-ID enthält Tab und Mobil (dom_id), Test „Frame-IDs eindeutig“.
  - L21 (Wiederverwendung): zweiter Sparkline-Controller kopierte Scope, Normalisierung und Cache-Key; jetzt gemeinsamer Concern AccountSetSparkline und Partial shared/_group_sparkline.
  - L1 (bekannte Art, Cache-Validator zu grob; CodeRabbit Minor, behoben in a564584f6): `stale?(etag:, last_modified: family.latest_sync_completed_at)` ließ einen Client mit nur If-Modified-Since nach Rechteänderung 304 bekommen. Prüffrage: Last-Modified nur, wenn es jede Änderung abdeckt, die die Antwort beeinflusst (Rechte, Freigaben); sonst ETag allein. Test mit nur If-Modified-Since.
- 22.10.2026, upstream PR 3510 (IBAN-Basis), Nachreview f649fa2f4, behoben in cc80921f6 (fix23/3510):
  - L7 (bekannte Art, Test ohne Trennschärfe): Der Test „keine IBAN-Übernahme auf ein Fahrzeug“ prüfte nur, dass die IBAN leer bleibt; das erzwingt Account#clear_unsupported_iban bei jedem Save ohnehin, der Test war ohne den neuen supports_iban?-Guard grün. Prüffrage: Gibt es eine zweite Schutzschicht (Callback, Validierung), die dasselbe Endergebnis erzwingt? Dann eine Nebenwirkung prüfen, die nur der neue Guard verhindert (hier: falscher DebugLogEntry aus der Konfliktprüfung).
  - L3/L1 (Altdaten, offen): Der Klartext-Weg über enrich_attribute lief vom 27.09. bis 22.10. im Fork-Branch production; dort können iban-Zeilen in data_enrichments liegen. Upstream main hatte den Weg nie. Prüffrage: Wird ein Klartext-Leck behoben, auch die eigenen Deployments prüfen, die den Zwischenstand liefen.
- 22.10. (upstream PR 4347, Review des Folge-Commits d60d2da48 „Queue drawer tag saves“, behoben in e9c69a857 auf fix23/4347):
  - L4/L8 (bekannte Art, Fehlerfall des Differenz-Protokolls): Die Warteschlange behob das Abbrechen, aber eine Anfrage, die serverseitig angewendet wurde und trotzdem scheiterte (500 beim Einreihen des Sofort-Regel-Jobs nach dem Speichern, verlorene Antwort), ließ savedIds auf dem alten Stand; das Zurücknehmen des Tags glich savedIds und wurde gar nicht gesendet, der Tag blieb gesperrt. Prüffrage: Bei Differenz-Protokollen (previous/next) für jeden Fehlerausgang einer Anfrage klären, ob der Server sie angewendet haben kann; unsichere Teile beim nächsten Speichern erneut als Änderung senden. Systemtest mit `Rule.stubs(...).raises.then.returns` und `page.server.reset_error!`.
- 21.–23.10.2026, Fork-PR-Job, behoben in den PR-Branches:
  - L1 (Eingabe/Encoding; Fork PR 142, 3000dae): `delete_prefix` mit BOM auf einer als Binärdaten gelesenen CSV-Zeile warf bei Nicht-ASCII-Zeichen Encoding::CompatibilityError (500). Dateiinhalte vor String-Operationen als UTF-8 lesen und scrubben.
  - L4 (Unique-Index-Reihenfolge; Fork PR 154, 1d29cac): external_id der Quellzeile wurde auf die Zielzeile kopiert, bevor die Quellzeile gelöscht war; der Unique-Index (account_id, external_id) lehnte ab. Erst löschen, dann übernehmen.
  - L8 (Zustand nach Turbo-Cache; Fork PR 137, fb09a50): Bestätigungsdialog übernahm beim Laden den aktuellen Text als Standard, nach Zurück-Navigation zeigte er die vorige Bestätigung. Zustand bei turbo:before-cache zurücksetzen.
  - L7 (N+1; Fork PR 161, 93b9f85): `rule.actions.count` löste trotz Preload pro Regel COUNT-Queries aus; `.size` nutzen und Query-Zahl im Test festhalten.
  - L4 (Fremdaufruf in Sperre; Fork PR 150, 6643b1e): Wechselkurs-Abruf lief innerhalb der gesperrten Transaktion; Provider-Abrufe vor Transaktion und Lock holen.
  - L1 (Cache-Validator; Fork PR 165, 17034f7): Antwort hing an der Turbo-Frame-ID, der ETag enthielt sie nicht (304 spielte den Body des ersten Frames ab). Alles, was die Antwort bestimmt (auch Request-Header), gehört in ETag oder Vary.
  - L7 (Test ohne Abdeckung; Fork PR 169, 0c2114c): Row-Cache ohne Tests; Cache-Hit, Invalidierung und Key-Bestandteile testen. Dazu L31: Doc-Kommentar zurück über die Methode.
  - L7 (Test prüft nur Nebensymptom; Fork PR 170, c1cc975): Mobil-Layout-Test prüfte nur Schalter und Menü, nicht den langen Namen und Chip, um die es ging. Bei Layout-Fixes das eigentlich überlaufende Element prüfen (Rechte Kante und scrollWidth ≤ clientWidth).
  - L6 (geteiltes Layout; Fork PR 170, c1cc975): flex-wrap in der Kopfzeile des Einstellungs-Layouts ließ umgebrochene Aktionen nach links springen, auf allen Einstellungsseiten; `ml-auto` hält sie rechts. Bei Änderungen an geteilten Layouts alle Nutzer der Stelle ansehen.
  - L6 (Kopfzeilen-Titel; Fork PR 170, deb0712): Beim Umbruch der Einstellungs-Kopfzeile blieb der Titel auf voller Breite; ein langer Dateiname (Kontoauszug) wurde abgeschnitten. In umbrechenden Flex-Zeilen jedes Textelement mit min-w-0 break-words versehen.
- 23.10.2026, Fork PR 171 (claude/project-thread-cuhjvv, Sortierung je Gruppierung), /code-review vor dem PR, behoben in 6ce3491de:
  - L4 (geteilte Liste, getrennt gespeichert): Die Untergruppen-Reihenfolge lag in einer Liste je Dimension, gespeichert wurde aber je Gruppe ohne Spiegelung; die veraltete Kopie einer anderen Gruppe überschrieb beim nächsten Speichern die Liste. Prüffrage: Was eine Speicherstelle teilt, muss auch dieselbe Speicher-Warteschlange und Spiegelung teilen, sonst je Liste getrennt speichern.
  - L1 (Altbestand bei neuer Ebene): Die neue Kontoreihenfolge je Gruppierung startete nach Namen und verwarf die schon gespeicherte Kontotyp-Reihenfolge. Prüffrage: Neue Sortierebene greift für noch nicht platzierte Einträge auf die bisherige Ordnung zurück.
  - L6 (verschachtelte Ziehlisten): dragend einer inneren Liste bubbelte zur äußeren und setzte aria-grabbed der per Tastatur gehaltenen Gruppe zurück. Prüffrage: Bei verschachtelten Listen jeden Drag-Handler (start, over, drop, end) auf „eigenes Element?“ prüfen.
  - L7 (Test ohne Trennschärfe): Untergruppen-Test erwartete die alphabetische Standardordnung. Gespeicherte Reihenfolge immer gegen die Standardordnung testen.
  - L21 (Wiederholung): dreifach kopierter sortable-list-Datenblock; jetzt Helper sidebar_sortable_list_data/item_data und Partial accounts/_sort_handle.
  - L6 (Grid ohne optionale Zeile; Fork PR 170, 6d47129a8): Regeln ohne Namen ließen im Grid eine leere erste Zeile; Platzierung und row-span an das Vorhandensein der optionalen Zeile koppeln. Bei Layouts mit optionalen Elementen jeden Fall (mit und ohne) im Screenshot prüfen.
- 23.10.2026, Fork PR 161 (claude/project-thread-yqdxpg, Filter als Popover), /code-review vor dem Push, behoben in fe4e2bb:
  - L6 (Radios im Suchformular): Enter auf einer Radio-Option löst implizites Absenden des GET-Formulars aus und lädt die Seite neu. Prüffrage: Neue Eingabefelder in einem Formular, das nur über ein Feld absenden soll, fangen Enter ab (keydown.enter → preventDefault).
  - L6 (Fokus nach Ausblenden): Der ✕-Knopf eines Filter-Badges blendet sein eigenes Badge aus, „Fertig“ schließt das Popover; der Fokus fiel jeweils auf body. Prüffrage: Versteckt eine Aktion das fokussierte Element, setzt sie den Fokus bewusst (hier zurück auf den Filter-Knopf).
  - L6 (nur Client-Zustand): Badges wurden nur per JS eingeblendet; ein Turbo-Morph setzt sie auf den Serverstand (versteckt) zurück. Prüffrage: Sichtbarer Zustand, der aus der URL folgt, wird serverseitig gerendert und vom Controller nur nachgeführt.
- 23.10.2026, Fork PR 172 (claude/project-thread-qim9n7, Budgets/Plan abschaltbar), /code-review vor dem PR, behoben in 08717dd:
  - L2 (Wege beim Abschalten einer Funktion): Budget-Seiten und API waren gesperrt, die Budget-Freigaben (Settings::BudgetSharesController) aber nicht. Prüffrage: Beim Abschalten einer Funktion alle Controller suchen, die ihre Daten schreiben, auch die unter settings/ und in der API.
  - L7 (datumsabhängiger Test): Der Insight-Test brauchte Ausgaben im laufenden Monat, die Fixture-Buchungen liegen aber 1–4 Tage zurück; an den ersten Tagen eines Monats wäre er rot gewesen. Prüffrage: Monatsbezogene Tests legen ihre Buchung selbst mit Date.current an.
  - L21 (Logik im View): Das Berichts-Partial fragte das Familien-Flag selbst ab, obwohl der Controller es schon prüfte. Das Flag läuft jetzt über metrics[:show_budget] aus dem Controller, damit es nur eine Quelle gibt.
- 24.10.2026, upstream PR 3510 (feat/iban-foundation, IBAN-Basis), cubic-Review vom 23.10. (23 Hinweise, 19 behoben, 4 begründet abgelehnt), behoben in c7ee0b354:
  - L1 (Normalisierung vor der Leer-Prüfung): Das Write-only-Feld prüfte `blank?` auf der Roheingabe; „-“ war nicht leer, wurde im Modell zu nil normalisiert und löschte die gespeicherte IBAN. Prüffrage: Leer-/Unverändert-Prüfungen laufen auf dem normalisierten Wert, nicht auf der Eingabe.
  - L6 (Formular nach Fehlschlag): Platzhalter und Entfernen-Schalter lasen `iban.present?` aus dem ungespeicherten Objekt; nach einem fehlgeschlagenen Speichern zeigten oder versteckten sie den Schalter falsch. Prüffrage: Zustandsanzeigen „gespeichert ja/nein“ lesen `attribute_in_database`.
  - L11 (RecordNotUnique pauschal): Der Rescue meldete jede Unique-Verletzung als IBAN-Fehler, auch die Namens-Index-Kollision. Prüffrage: Bei mehreren Unique-Indizes den verletzten Index aus der Fehlerzeile lesen (nicht aus DETAIL, das enthält Nutzereingaben) und Unbekanntes weiterwerfen.
  - L2 (Nebenweg im Rebuild-Pfad): `remove_iban` wurde in create/update entfernt, im 422-Rebuild nicht (UnknownAttributeError). Prüffrage: Jeder Pfad, der Params ans Modell gibt, filtert dieselben Nicht-Attribute.
  - L16 (Provider-Sync): Assoziation vor dem Anlegen als nil gecacht (Log ohne account_provider); beim Relink blockierte das alte Konto die IBAN; fehlgeschlagene Speicherungen loggten bei jedem Sync. Prüffrage: Nach `x.present?`-Checks über die Assoziation anlegen; bei Umhängen erst freigeben, dann übertragen; wiederkehrende Sync-Fehler nur einmal loggen.
  - L13 (Migration down): `down` brach mit roher Unique-Verletzung ab und ließ einen ungültigen Index zurück. Prüffrage: Auch `down` bekommt den Duplikat-Preflight mit IDs und einen Migrationstest.
  - L1 (Import, Währungswechsel): Der Import behielt die vorhandene IBAN, die in der neuen Währung schon vergeben war; save! hätte den Import abgebrochen. Prüffrage: Ändert ein Import einen Teil des Unique-Schlüssels, den behaltenen Wert neu prüfen.
  - L7 (Tests): doppelter Test, Test ohne Mindestanzahl (`next unless` konnte alles überspringen), Fehlermeldung ohne ID-Prüfung.
- 24.10.2026, upstream PR 4347 (feat/rules-apply-immediately, Regeln sofort anwenden), cubic-Review vom 23.10. (15 Hinweise, 12 behoben, 3 begründet abgelehnt), behoben in 42242d4 und 3153c30; dazu 4 Befunde aus dem eigenen /code-review max auf die Fixes:
  - L6 (Erfolg falsch erkannt): Die API rief den Folge-Job mit `if @transaction` auf, das ein before_action schon gesetzt hatte; ein abgelehntes Update löste ihn trotzdem aus. Prüffrage: Folgeaktionen hängen an einem Flag, das nur der Erfolgszweig setzt, nie an einer Instanzvariablen aus dem Laden.
  - L11 (Race, nicht alle Schreiber gesperrt): Das Tag-Zusammenführen im Drawer las und schrieb ohne die Zeilensperre, die toggle_tag! und die Regel-Aktion nehmen. Prüffrage: Alle Schreiber desselben Felds nehmen dieselbe Sperre; das Lesen passiert nach dem Sperren (im Modell, nicht im Controller).
  - L5 (N+1): Snapshot je Eintrag mit eigener Tagging-Abfrage in bulk_update!. Prüffrage: Vorher-/Nachher-Vergleiche in Schleifen laden Zuordnungen einmal gesammelt.
  - L26 (Zustandsübergang statt Zustand): fail_job! hätte bei jedem Sidekiq-Retry erneut den Toast gesendet, weil nur „pending == 0“ geprüft wurde. Prüffrage: Einmalige Nebenwirkungen (Broadcast, Mail) hängen am Übergang, der im Lock festgestellt wird, nicht am Endzustand.
  - L28 (Zählerbedeutung): Bei asynchronen Runs stehen die synchronen Änderungen in transactions_processed, nicht in transactions_modified; gemischte Regeln boten ihr Ergebnis nie an. Prüffrage: Vor dem Auswerten eines Zählers nachlesen, wer ihn in welchem Modus wie befüllt.
  - L29 (Kommentar widerspricht Code): Die Ignorierliste schloss `excluded` aus, obwohl die Split-Aktion es liest. Prüffrage: Bei „liest niemand“-Listen jede Spalte per rg in Bedingungen und Aktionen suchen.
  - L6 (Frontend, stille Fehler): Fehlgeschlagenes Tag-Speichern blieb unsichtbar; eine HTML-Antwort nach Redirect hätte als Erfolg gegolten. Prüffrage: fetch-Erfolg = ok, nicht redirected, erwarteter Content-Type; Fehler sichtbar machen, ohne Layout (absolut verankerte Menüs) zu verschieben.
  - L7 (Tests): Ein Test bestand auch ohne Fix, weil die untere Regel nach der Umbenennung nicht mehr passte; ein Sperr-Test stubbte with_lock weg. Prüffrage: Jeder neue Test wird einmal ohne den Fix ausgeführt und muss rot sein.
- 24.10.2026, Fork-Branch claude/project-thread-k7e9gx (upstream issue 1206, Einladungen an bestehende Accounts sperren), eigenes /code-review max vor dem PR, 7 Befunde behoben in bd38163:
  - L7 (Tests): Ein bestehender Test legte eine Einladung für ein Mitglied an und brach mit der neuen Validierung (volle Suite rot). Prüffrage: Nach einer neuen Validierung alle `create!` des Modells in test/ per rg auf Fixture-Daten prüfen, die sie verletzen.
  - L2 (Wege): Nur der Passkey-Login hatte einen Test für „Einladung bleibt offen“; Passwort-Login ergänzt. Prüffrage: Wird ein Aufruf aus mehreren Login-Wegen entfernt, je Weg ein Test, mindestens für die Hauptwege.
  - L2 (Sackgasse): Wer sich ohne Token registriert, landete auf einer Annahmeseite mit „Neues Konto“, das am vergebenen E-Mail scheitert. Prüffrage: Nach dem Entfernen eines Wegs jeden verbliebenen Button der Seite mit dem neuen Zustand durchspielen.
  - L29 (Verwaiste Verweise): Kommentare in vier Dateien und `ProviderItemOwnable.owned_item_classes` verwiesen auf das gelöschte `accept_for`. Prüffrage: Nach dem Löschen einer Methode rg nach dem Namen in app/, lib/, test/ und in Kommentaren.
  - L11 (i18n): Neue Keys nur in en/de, obwohl 13 weitere Locale-Dateien im Diff angefasst wurden. Prüffrage: Wer eine Locale-Datei ändert, ergänzt dort auch die neuen Keys.
  - L13 (PR-Text): Der Fix ändert gewolltes Upstream-Verhalten (Übernahme bestehender User, upstream issue 3884); das muss im PR-Text stehen.

- **24.10.2026, Fork 173 (Saldo zählt Überweisungen bei sonstigem Vermögen/Verbindlichkeit), vor-pr-Review:**
  L2: Hängt ein Saldo neu an einem Feld (hier `kind`), dann alle Wege prüfen, die dieses Feld ändern, ohne einen Sync anzustoßen (confirm!, reject!, unlink, Leg-Löschung, Konto-Löschung, Assistant). Behoben: Sync im Model (Transfer) statt in jedem Controller. L1: Begleitzeilen mitdenken (Überweisungsgebühren mit transfer_id und Art standard). L11: Hinweistext, dessen Aussage sich umkehrt, in allen Locales ändern, nicht nur en/de. L7/L27: ausgenommene Typen (Property/Vehicle) mit eigenem Test absichern. Testfalle: `assoc.destroy_all` auf einer schon geladenen has_many-Assoziation löscht beim zweiten Mal nichts; in Tests `Model.where(...).delete_all` nehmen.

- **24.10.2026, Fork 155 → Upstream-Branch claude/project-thread-n49j7k (Händlerliste merkt Seitengröße), vor-pr-Review max, 2 Befunde behoben in 92f00d5:**
  - Korrektur zur Prefetch-Prüffrage oben (Zeile „Turbo-Prefetch …“): Prefetch-Anfragen nur auszunehmen reicht nicht. Turbo 8 beantwortet den Klick mit der Antwort des Hover-Prefetches und schickt keine zweite Anfrage; ein ausgenommener Prefetch heißt also, der angeklickte Zustand wird nie gespeichert. Prüffrage: Schreibt ein GET Zustand, den ein Link-Klick ändern soll, dann die Links mit `data-turbo-prefetch="false"` ausnehmen (oder den Prefetch mitschreiben), nicht nur den Prefetch serverseitig ignorieren. Test: Attribut per assert_select.
  - L33/L7 (Eingabetypen): `value.match?` auf Werten aus `params.permit` brach mit NoMethodError, weil JSON-Bodies auch bei GET Integer/Float/true durchlassen. Prüffrage: Auf permitted Scalars nie String-Methoden ohne `.to_s` aufrufen; Test mit `as: :json`.

- **24.10.2026, Fork 138 → Upstream-Branch fix/destroy-job-failure-logging (DestroyJob protokolliert Löschfehler), vor-pr-Review max, 5 Befunde behoben:**
  - L22 (Ursache statt Symptom) / L2: Ein neues `retry_on` im Job lief, nachdem das Model (Account#destroy) den Zustand schon zurückgesetzt hatte (pending_deletion → disabled). Der Retry hätte ein inzwischen wieder aktiviertes Konto gelöscht. Prüffrage: Wer ein Retry einführt, prüft, ob tiefere Schichten im Fehlerfall schon Zustand zurücksetzen; Rücksetzen erst, wenn der Job aufgibt.
  - L1 (Datenrandfälle): `update_column` umgeht Validierungen, aber keine partiellen Unique-Indizes, deren Bedingung die Spalte selbst ist (trade_republic_items, `scheduled_for_deletion = false`). Prüffrage: Beim Zurücksetzen eines Flags in db/schema.rb nach `where:` mit dieser Spalte suchen.
  - L13 (Diagnose): Ein selbst geworfenes RecordNotDestroyed ohne `errors.full_messages` verliert den Abbruchgrund. Und ein Restore auf einem schon gelöschten (frozen) Datensatz ersetzt den echten Fehler durch FrozenError. Prüffrage: Bei Fehlerprotokollen den Grund (errors, cause) mitschreiben und `destroyed?` vor Zustandsänderungen prüfen.
  - L31 (Zeitbezug): Feste 3 s × 3 Versuche decken einen laufenden Sync nicht ab; polynomially_longer mit 5 Versuchen.

- **24.10.2026, Fork 140 → Upstream-Branch fix/data-cache-clear-family-refresh (Fork-PR 176, Cache leeren je Familie), upstream-Review max, 6 Befunde behoben:**
  - L1 / L22 (Datenrandfälle, Ursache): `clear_cache` überschrieb in beiden Importern (Kurse, Preise) jeden Tag im Fenster. Liegt gespeicherte Historie vor dem ersten Provider-Wert (früherer Provider, kürzere Abdeckung), wurde der Startwert über alle diese Tage fortgeschrieben und echte Historie instanzweit plattgemacht. Prüffrage: Wer gespeicherte Werte durch Provider-Werte ersetzt, ersetzt nur im Bereich, den der Provider tatsächlich liefert; Test mit Historie vor dem ersten Provider-Datum.
  - L13 (Verhalten unverändert): Beim Herauslösen einer Methode rutschte ein Guard (`needs_exchange_rates?`) hinter den Provider-Lookup. Prüffrage: Bei Extraktion die Reihenfolge der Guards im alten Aufrufer beibehalten.
  - L21 (Wiederverwendung): Fenster-Merge doppelt (MarketDataImporter und Refresher) → `Window#merge`.
  - L16 (Provider-Diagnose): DebugLogEntry ohne `provider` → nicht unter dem Provider-Filter sichtbar.
  - L10 (Tests): Reihenfolge „erst Refresh, dann Holdings löschen“ war von keinem Test abgedeckt (alle stubbten den Refresh).
  - L29 (veraltete Texte): Job-Kommentar und Test-Meldung beschrieben noch das alte Löschverhalten.

- **24.10.2026, Fork 141 → Upstream-Branch claude/project-thread-74197v (Kurs-Import-Sperre pro Paar), upstream-Review max, 2 Befunde behoben (+3 Aufräum-Punkte):**
  - L4 (Nebenläufigkeit): Eine Session-Advisory-Sperre wurde im `ensure` freigegeben. Lief der Import in einer offenen Transaktion des Aufrufers (Demo-Generator) und schlug eine SQL-Anweisung fehl, war die Transaktion abgebrochen, das Unlock warf `InFailedSqlTransaction` und die Sperre blieb auf der Pool-Verbindung hängen. Prüffrage: Bei Session-Sperren mit Unlock im `ensure` prüfen, ob der Block in einer fremden Transaktion laufen kann; dann Savepoint (`requires_new`) um den Block und Test mit fehlschlagendem SQL.
  - L4 / L14 (Warten ohne Nutzen): Die Sperre wurde genommen, bevor geprüft wurde, ob überhaupt etwas zu importieren ist; Syncs mit vollständigen Kursen hätten bis zu 120 s gewartet. Prüffrage: Bei wartenden Sperren den billigen „nichts zu tun“-Check vor die Sperre ziehen (und danach wiederholen).
  - L29 (veraltete Texte): TwelveData-Kommentar verwies noch auf die entfernte 5-Minuten-Cache-Sperre. L21: Sperrschlüssel im Test nachgebaut statt öffentlicher Key-Methode; Provider-Name ein viertes Mal hergeleitet statt `ExchangeRatePair.resolve_provider_name`.

- **24.10.2026, Fork 152 → Upstream-Branch fix/save-and-lock-atomic (Speichern und Sperren atomar), upstream-Review max, 6 Befunde behoben (+6 begründet abgelehnt):**
  - L10 (Tests nach Rebase): Ein Test mit `use_transactional_tests = false` löschte im Teardown die Familie per `delete_all`; seit upstream die Familie beim Anlegen Klassifizierungsregeln bekommt (after_create_commit), scheiterte er bei jedem Lauf am Fremdschlüssel. Prüffrage: Nach dem Holen von main nicht-transaktionale Tests neu laufen lassen; Teardown wie die Geschwister-Tests (`Rule.where(family_id:).destroy_all` vor der Familie).
  - L4 (Sperr-Reihenfolge): Eine neue Zeilensperren-Reihenfolge (Transaktion vor Eintrag) gilt erst, wenn alle Stellen sie nutzen, die beide Zeilen sperren oder schreiben. Übersehen waren Entry#enrich_attributes (Claim-Pfad im Import), API-/Assistant-Update, Bulk-Edit, FinanceKit (`entry.lock!`) und merge_with_duplicate!. Prüffrage: Bei neuer Sperr-Reihenfolge per `grep "\.lock!"` und nach Schreibfolgen alle Gegenstellen auflisten.
  - L4 (veraltete Daten nach Warten): Wer auf eine Zeilensperre wartet, muss danach frisch lesen, was er zusammenführt (hier `locked_attributes`), sonst überschreibt er das Ergebnis des Wartens.
  - L4 (verschachtelte Transaktion): `raise ActiveRecord::Rollback` in `transaction do` ohne `requires_new` wird in einer äußeren Transaktion verschluckt; der Test grünt nur, weil die Fixtures eine nicht-joinbare Transaktion öffnen. Prüffrage: Helfer, die per Rollback zurückrollen, mit `requires_new: true` und Test in `Entry.transaction do … end`.
  - L2 (Wege-Tabelle): Den Recheck unter Sperre an allen Schreibwegen eines Imports einbauen (hier fehlte die Übernahme eines manuellen Duplikats).
  - L10 (volle Suite): `Model.where(...)` in einer Instanzmethode, die aus einer Klassenmethode auf einer Relation heraus läuft (`Entry.bulk_update!` über `all.each`), erbt deren Scope (DISTINCT, includes) → `FOR UPDATE is not allowed with DISTINCT`. Prüffrage: Zeilensperren und Einzel-Lookups per id mit `unscoped` bauen, und nach Review-Fixes immer die volle Suite laufen lassen, nicht nur die betroffenen Dateien.

- **24.10.2026, Fork 157 → Upstream-Branch fix/split-row-merchant (Fork-PR 180, Händler bei Split-Zeilen), Review max vor Upstream, 4 Befunde behoben:**
  - L6 / L34 (Turbo-Stream-Zustand): Nach einer Händleränderung am Elterneintrag wurden die Split-Zeilen flach statt in der Split-Gruppe ersetzt, weil der Drawer des Elterneintrags nie `grouped=true` trägt. Prüffrage: Wer per Turbo-Stream Zeilen ersetzt, die von einem anderen Drawer aus geändert wurden, leitet den Darstellungsmodus aus dem Zielkontext ab, nicht aus Params des auslösenden Drawers; Test prüft Markup (Link/Einrückung), nicht nur das Ziel.
  - L14 (Index): Callback suchte den Elterneintrag per `entryable_id` (kein Index) bei jeder Händleränderung jeder Transaktion; jetzt `entry.id` + Index auf `parent_entry_id`.
  - L1 (Datenrandfall): `locked_attributes` mischte String- und Symbol-Key `merchant_id` (json-Duplicate-Key-Warnung, ab json 3.0 Fehler). Prüffrage: jsonb-Hashes mit einheitlichen String-Keys bauen.
  - L14 (N+1): ersetzte Zeilen ohne Preload gerendert; jetzt `includes`.

- **24.10.2026, Fork 161 → Upstream-Branch claude/project-thread-er202b (Fork-PR 182, Regel-Gruppen), Merge auf main + Review max vor Upstream, 8 Befunde behoben:**
  - L26 (Reihenfolge, gemeinsame Positionsfolge): Upstream `Family#add_classifier_rule!` schob nur `rules` um 1 nach unten; mit `rule_groups` in derselben Folge landete eine Gruppe vor der losen Regel davor. Prüffrage: Nach jedem main-Merge `grep "position = position"` und `update_all.*position` über alle Tabellen derselben Positionsfolge.
  - L34 (sichtbares Ergebnis, Turbo-Morph): Der Faltzustand wurde nur in `connect()` angewendet; ein Morph-Refresh (Regel-Schalter → `stream_redirect_back_or_to`) öffnete die Gruppen, das `toggle`-Event löschte den gespeicherten Zustand. Prüffrage: Jeder Stimulus-Controller, der Server-Markup clientseitig umstellt (hidden, open, draggable), hört auf `turbo:morph@window`; Systemtest „Zustand nach Refresh“.
  - L1 (CSV-Randfall): Gruppen-Spalte per `headers.compact.size` gezählt; eine leere Kopfzelle verschob die Spalte. Kopfzeilenlänge aus der Rohzeile nehmen.
  - L4 (Sperrreihenfolge): `after_save` nahm die Advisory-Sperre erst nach dem Zeilen-UPDATE, alle anderen Positionsschreiber umgekehrt → Deadlock möglich. Sperre in `before_save` nehmen. Dazu `create_or_find_by!` rettet nur RecordNotUnique, nicht `:taken` aus der Uniqueness-Validierung.
  - L3 (Fehlerweg): `render :new, status: 422` bei Formular mit `turbo_frame: :_top` ersetzt die ganze Seite durch den Dialog. Redirect mit Alert.
  - L25 (Rechte in Data-Attributen): Filter-Optionen waren auf sichtbare Konten gefiltert, `data-rule-accounts` aber nicht (UUIDs fremder Konten im DOM).
  - L9 (Doku): Neuer Reset-Zähler ohne `docs/api/openapi.yaml`-Regenerierung.
  - L27 (Anzeige): Suchtext nahm bei Split-Aktion das rohe JSON statt `executor.value_display`.

- Nachtrag 24.10.2026, Fork 167+169 → Fork 183 (Zeilen-Fragment-Cache der Buchungsliste), /code-review max:
  - L24/L9 (Fragment-Cache, neue Fehlerart „gecachte Formulare“): Gecachte Zeile enthielt `button_to`-Formulare (Transfer bestätigen/ablehnen) mit dem CSRF-Token der Browser-Sitzung; das Ablehnen-Formular läuft ohne Turbo (kein X-CSRF-Token-Header) → InvalidAuthenticityToken auf zweitem Gerät. Prüffrage: Jeder `cache`-Block nach `button_to`/`form_with` in allen Zuständen durchsuchen; Sitzung (gehasht) in den Schlüssel oder Formular außerhalb des Caches.
  - L9 (Cache-Schlüssel unvollständig): Inflow-Zeile hängt von `kind` des Outflow-Beins ab, Schlüssel hatte nur dessen Kategorie. Prüffrage: Für jede Helper-Verzweigung im gecachten Partial den gelesenen Datensatz im Schlüssel nachweisen, je Teil ein Test, der ohne ihn rot ist.
  - Effizienz (3.8): `cache_key_with_version` von Konto/Kategorie wechselt bei jedem Saldo-Sync bzw. `touch(:last_used_at)`; für angezeigte Daten nur die angezeigten Attribute schlüsseln.
- **24.10.2026, upstream PR 4464 (Händlerliste merkt Seitengröße), CodeRabbit Runde 1, 2 Befunde behoben:**
  - L1 (Datenrandfälle, Gegenrichtung): Gespeicherter Zustand wurde nur über `request.query_parameters` gesteuert; JSON-Body-Parameter wurden bei vorhandenem Zustand übergangen, und eine Anfrage nur mit unbekannten Parametern löschte den Zustand. Prüffrage: Bei „Zustand merken/wiederherstellen“ beide Richtungen testen: (a) Eingabe aus Query UND Body, mit und ohne bereits gespeicherten Zustand, (b) Anfrage ohne erlaubte Parameter darf nichts überschreiben. Entscheiden über `params.keys & ERLAUBTE_KEYS`, nicht über Query-String.
- **24.10.2026, upstream PR 4465 (Kurs-Import-Sperre), Bot-Review CodeRabbit + Codex, 2 Befunde behoben (4ca0ab0):**
  - L4 (Nebenläufigkeit): Ein vor dem Warten gebautes Objekt mit memoisiertem Zustand (Importer#clamped_start_date aus first_provider_rate_on) wurde nach dem Warten weiterverwendet; die wartende Seite sah nicht, was die erste gespeichert hatte, und rief den Provider erneut. Prüffrage: Alles, was nach dem Erwerb einer Sperre gelesen werden soll, erst nach dem Erwerb laden (frisches Objekt, kein Memo von vorher); Test, der den Zustand während des Wartens ändert.
  - L16 (Provider-Diagnose): Neuer DebugLogEntry ohne Konto/Familie, obwohl der Aufrufer (Account::MarketDataImporter) das Konto kennt. Prüffrage: Bei jedem neuen DebugLogEntry den Kontext aller Aufrufer durchreichen, wo vorhanden.
- **24.10.2026, Fork 154 (Remap/Reset mit negativen Holdings), /code-review max vor Upstream, 6 Befunde behoben; danach Duplikat upstream PR 4391 gefunden:**
  - L1 (Datenrandfälle): Validierungen per `update_columns`/`update_all` zu umgehen öffnete die Merge-Arithmetik für negative Zeilen (gewichtete Kostenbasis und Preis wurden negativ gespeichert). Prüffrage: Wer Validierungen umgeht, prüft jede abgeleitete Rechnung im selben Pfad mit negativen Eingaben (je ein Test).
  - L16 (Diagnose): Neue Rescues mit `Rails.logger.warn` statt `DebugLogEntry.capture`, obwohl die Meldung auf den Support verweist. Prüffrage: Jeder neue Rescue mit Support-Hinweis schreibt einen DebugLogEntry mit Konto-Kontext.
  - L17 (Duplikate): Die Upstream-Duplikatsuche lief erst beim PR-Anlegen, nach Review und Umbau. Prüffrage: Duplikatsuche upstream als ersten Schritt eines „Fork NN für upstream“-Threads.

- **24.10.2026, upstream PR 4469 (DestroyJob), Bot-Befunde nach dem Öffnen (Codex P1, CodeRabbit), 3 behoben:**
  - L22/L2: `retry_on` für Fehler, die nach dem Commit des Löschens fallen, läuft ins Leere: der Retry kann den gelöschten Datensatz nicht laden, `discard_on ActiveJob::DeserializationError` verwirft ihn still. Prüffrage: Bei Retries im Lösch-Job prüfen, ob der Datensatz danach noch existiert (`destroyed?`), sonst sofort melden.
  - L13: Aufräumschritte (Restore) in `ensure`, damit ein scheiternder Log-Schreibvorgang sie nicht überspringt; ein gescheiterter Restore gehört ins selbe Debug-Log wie der Ursprungsfehler.
  - Nachtrag upstream PR 4468 (Bots, 24.10.): L4 erneut: `unlock_for_sync!` (Eintrag vor Buchung) und `Entry#destroy` (Eintrag vor Buchung über dependent: :destroy) fehlten in der Gegenstellen-Liste; Prüffrage schärfen: auch Entsperr- und Lösch-Wege auflisten (`grep "update!(.*locked_attributes"`, `destroy`). L13 (Rückgabevertrag): Ein Rescue, das ein gelöschtes Objekt als Ergebnis zurückgibt, bricht Aufrufer, die es weiterreichen (FinanceKit `identity.update!(entry:)`); bei „gelöscht während des Imports“ einen gültigen Zustand zurückgeben.

- **24.10.2026, upstream PR 4467 (Split-Zeilen-Händler), Codex + CodeRabbit, 2 Befunde behoben (fb71936):**
  - L4 (Race): Callback lud Kind-Zeilen per `find_each` und schrieb ohne Sperre; eine parallel gespeicherte Drawer-Änderung des Kinds wurde überschrieben. Prüffrage: Wer in einem Callback andere Datensätze bedingt ändert, prüft die Bedingung unter `with_lock` erneut (oder bedingtes atomares Update).
  - L1 / L22 (Zustand aus Gleichheit abgeleitet): „geerbt“ wurde nur aus Gleichheit mit dem alten Elternwert geschlossen; ein per Regel gesetzter, zufällig gleicher Händler galt danach als geerbt. Prüffrage: Herkunft (geerbt vs. eigen) explizit speichern oder beim Zusammenfallen sperren, nicht aus Wertgleichheit raten.

- **26.10.2026, Fork PR 184 (Kontonamen in Regeln, /code-review vor PR):**
  L2 geschärft: Eine Regel-Aktion, die Buchungen in ein Zielkonto schreibt, braucht writable_by, nicht accessible_by (Nur-lesen-Freigabe reicht nicht). L2/L24: Rechte-Scopes mit Current.user brauchen einen Weg ohne Nutzer (Mailer/Jobs rendern Regeltitel, z. B. Regel-Digest-Mail; accessible_by(nil) wirft). L1: Selects mit gespeichertem Wert, der nicht (mehr) in den Optionen steht, springen beim Speichern still auf die erste Option; gespeicherten Wert als Platzhalter-Option halten. IDs aus Imports case-insensitiv vergleichen.

- **26.10.2026, PR-Check-Reviews (upstream 4468, 4475, 4347/4466, 4474, 4464, 4466), 6 Befunde behoben:**
  - 4468, L4/L2: Der Pending→Posted-Claim im Provider-Import las Betrags- und Datumssperren aus einer ungesperrten Kopie; eine parallel gesetzte Nutzersperre wurde überschrieben (Probe 99 → 72). Prüffrage: Jeden Schreibweg eines Imports einzeln auflisten (bestehende ID, Duplikat-Claim, Pending-Claim, Skip) und für jeden die Sperre vor dem Lesen der Schutzbedingungen belegen. Nach dem Lock ALLE Vorbedingungen neu prüfen (auch `external_id IS NULL` des Duplikats).
  - 4475, L9: Ein Cache-Key-Teil aus `session.id` ist nil, solange das Session-Cookie fehlt (erster Aufruf nach Browser-Neustart); `compact!` lässt ihn still weg, alle cookielosen Sitzungen teilen sich das Fragment mit CSRF-Token. Prüffrage: Sitzungsgebundene Inhalte (CSRF-Formulare) nicht fragment-cachen (`cache_unless`), statt sie per Session zu schlüsseln. L9: Jede Verzweigung im Template gehört in den Key, auch abgeleitete (`supports_trades?` hängt am Krypto-Subtyp).
  - 4347/4466, L5/L17: Zwei eigene offene PRs nutzten dieselbe Migrationsversion; `db/schema.rb` mergt dann konfliktfrei, `db:migrate` wirft aber DuplicateMigrationVersionError. Prüffrage: Migrationsversion gegen alle eigenen offenen PRs prüfen; umbenannt wird der PR, dessen Migration noch nicht in Fork-production gelaufen ist.
  - 4474, L13: Testname und Commit-Text versprachen „gescheitertes Enqueue rollt zurück“, obwohl `enqueue_after_transaction_commit` gilt. Prüffrage: Rollback-Behauptungen gegen den tatsächlichen Enqueue-Zeitpunkt prüfen.
  - 4464, L7: Ein Test mit `minimum: 1` deckte nur einen von zwei Blöcken ab (Fixture ohne Provider-Händler). Prüffrage: Bei mehreren gleichartigen Stellen `count:` prüfen und Fixtures für jede Stelle anlegen.
  - 4466, L7: Ein Test stand eingerückt unter `private` (läuft, liest sich aber wie ein Helfer).
  - 4347, L16: Ein Zähler offener Jobs (`pending_jobs_count`), den auch Sidekiq-Retries herunterzählen, darf nicht allein über „zuletzt geleert“ entscheiden: ein erfolgreicher Retry nach einem Fehlschlag fand 0 vor und bot sein Ergebnis nie an. Prüffrage: Was passiert bei fail → retry → success mit einem einzigen Job?
  - 4467, L14 (verworfen): `entry&.excluded?` als Vorab-Filter im Transaktions-Callback brach 5 Split-Tests, weil das geladene `entry` beim Speichern der Transaktion veraltet sein kann. Prüffrage: Vorab-Filter in Callbacks nur auf frisch gelesenen oder eigenen Spalten aufbauen.
  - 3510, L8: Constraint-Namen nie aus der Fehlermeldung parsen (lc_messages kann übersetzt sein → 500); `error.cause.result.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)` nutzen, Regex höchstens als Fallback. Tests mit gestubbter englischer Meldung decken das nicht ab.

- **26.10.2026, upstream PR 4469 (DestroyJob), PR-Check + CodeRabbit-Major, 1 Befund behoben (20ba9ae):**
  - L13/L2: Ein Wiederherstellungsweg nach einem Fehler (`restore_after_failed_destroy`) feuerte AASM-Bang-Events, die mit Validierungen speichern; eine fremde Validierung (Besitzer nicht mehr in der Familie) ließ das Konto unsichtbar in `pending_deletion` und ersetzte den Ursprungsfehler im Log. Prüffrage: Recovery-Pfade schreiben den Zustand direkt (`update_columns`/bedingtes `update_all`) und können an keiner Validierung scheitern, die mit dem Fehler nichts zu tun hat.

- **26.10.2026, upstream PR 4347 (Sofort-Regeln), PR-Check, 1 Befund behoben (1d03669):**
  - L13/L7: Eine KI-Aktion meldet als `modified_count` die an die KI übergebenen Buchungen; der Sofort-Job las diese Zahl als „geändert“ und bot den Neu-laden-Hinweis bei jeder Änderung an. Prüffrage: Bei jedem Zähler, der eine Entscheidung steuert (Hinweis, Mail, Retry), nachlesen, was jeder Beitragende wirklich hineinzählt (hier: übergeben vs. geändert); Test mit einer Regel, die nur an die KI übergibt.
  - Gegenprobe zum PR-Check: Die Behauptung „abgelehntes API-Update startete die Regeln nie, Rails setzt beim Rollback die Werte zurück“ war falsch; mit dem alten Controller ist der Test rot (`raise ActiveRecord::Rollback` setzt die Attribute im Speicher nicht zurück). Prüffrage: „Test ist auch ohne Fix grün“ immer durch tatsächliches Zurücksetzen des Fixes belegen, nicht herleiten.

- **26.10.2026, upstream PR 4467 (Split-Händler), PR-Check + /code-review max, 4 Befunde, 3 behoben (74e939f):**
  - L1/L13: Der Drawer bot „(none)“ an, aber im Split-Editor hieß leer „Händler der Hauptbuchung“, deshalb ging „kein Händler“ beim Neu-Splitten verloren. Prüffrage: Hat derselbe Leerwert in allen Formularen, die dieselbe Spalte bearbeiten, dieselbe Bedeutung? Und überlebt ein Rundweg (bearbeiten, speichern, wieder öffnen, speichern) jeden Zustand, auch die Sperren?
  - L26: Der Split-Editor lud die Zeilen ohne ORDER BY (jetzt `created_at, id`).
  - L10: Die Folge-Regel (ungesperrt und gleicher Händler wie die Hauptbuchung) stand im View-Helper, jetzt in `Transaction#follows_parent_merchant?`.
  - L2/L7: Der Platzhalterwert war nur für update getestet; ein create-Test kam dazu.
  - Offen (L15): Ein API-PATCH kennt „eigener Händler“ und „kein Händler“ nicht; ein Rundweg über die API löst diese Zustände wieder auf.

- **26.10.2026, Fork PR 185 (KI-Job-Wiederholungen zählen doppelt, /code-review vor PR), 1 Befund behoben:**
  - L4/L22: Ein Zähler pro Lauf (`pending_jobs_count`), den Jobs selbst herunterzählen, muss pro Job idempotent sein: Sidekiq wiederholt unter derselben job_id und stellt mindestens einmal zu. Der erste Fix machte nur den Zähler idempotent, die mitaddierte Änderungszahl (`transactions_modified`) zählte bei erneuter Zustellung doppelt. Prüffrage: Jeden Wert, den ein Job-Rückmelder schreibt (Zähler, Summen, Status, Fehlertext), für fail → retry → success und für doppelte Zustellung nach Erfolg einzeln durchspielen.

- **26.10.2026, Fork PR 189 (Ausgaben-Donut: verrechnete Kategorien, upstream Issue 2902), /code-review vor PR, 4 Befunde behoben (77f6a2e):**
  - L6/L13: Der neue Hinweis erklärt fehlende Kategorien, aber die Sichtbarkeit des Widgets hing weiter nur an `categories.present?`; im verwirrendsten Fall (alles erstattet) verschwand das Widget samt Hinweis. Prüffrage: Hängt die Sichtbarkeit des Containers auch von dem neuen Inhalt ab, den der Diff hinzufügt? Test für „nur der neue Inhalt“ schreiben.
  - L10: Für die Liste wurden `CategoryTotal`s mit Bruttobetrag und Schein-Gewicht 0 gebaut, neben Geschwistern mit Nettobetrag. Prüffrage: Trägt ein wiederverwendeter Werttyp in jedem Feld dieselbe Bedeutung wie bei den Geschwistern? Sonst nur das liefern, was der Aufrufer braucht.
  - L10/L12: Link-Aufbau mit Verzweigung stand im ERB, und dieselbe Transaktions-URL wurde zweimal gebaut; jetzt Helper plus eine Controller-Methode.
  - L7: Ein Controller-Test löschte die Fixture-Buchungen nicht; die Fixtures enthalten bereits eine verrechnete Kategorie, der „kein Hinweis“-Test war deshalb zuerst rot.

- **26.10.2026, Fork PR 190 (SimpleFIN-Backfill für neu verknüpfte Konten, upstream Issue 2864), /code-review vor PR, 3 Befunde behoben (426fcf5):**
  - L8/L1: Der erste Entwurf setzte die „History geholt“-Markierung nur für Konten, die im Lauf zurückkamen. Ein Konto, das der Provider nie liefert (geschlossen, Login abgelaufen), hätte den teuren Rundlauf bei jedem Sync erzwungen und das Tageslimit von SimpleFIN aufgebraucht. Prüffrage: Kann eine neue Auslösebedingung für einen teuren Provider-Abruf dauerhaft wahr bleiben, wenn der Provider ein Objekt nie liefert? Abschlussmarkierung an den Lauf hängen, nicht an das Ergebnis pro Objekt; nur abgebrochene Läufe wiederholen.
  - L2: Auch der Onboarding-Weg zählt: Der erste Sync einer neuen Verbindung läuft vor dem Verknüpfen; eine nur für verknüpfte Konten gesetzte Markierung hätte direkt danach einen zweiten vollen Lauf ausgelöst. Prüffrage: Jeden Weg durchspielen, auf dem ein Objekt in den Zustand „verknüpft“ kommt (Setup, Relink, Repair, später verknüpfen).
  - L1: nil („nie geholt“) und [] („geholt, leer“) auf einer Payload-Spalte als Signal zu nutzen, war zu implizit; eine eigene Zeitstempel-Spalte macht den Zustand ausdrücklich.

- **26.10.2026, Fork PR 191 (Import-Konten gehören dem importierenden Nutzer, upstream Issue 2997), /code-review vor PR, 5 Befunde behoben (4300e95):**
  - L2/L3: Wer einen Owner ändert, ändert auch die Sichtbarkeit. Neue Import-Konten gingen am Familien-Standard „geteilt“ vorbei (nur `Account.create_and_sync` teilt automatisch); der Admin hätte Konten des Mitglieds verloren. Prüffrage: Läuft jeder neue Anlage-Weg durch dieselbe Teilen-Logik wie die UI?
  - L29: Konten, die einem Mitglied gehören, wandern bei `transfer_to_family!` mit, behielten aber `import_id` der alten Familie; ein Revert dort hätte sie gelöscht. Prüffrage: Welche Verweise (import_id, statement, provider) zeigen nach einem Familienwechsel noch in die alte Familie?
  - L2: Ein Import kann von einem anderen Mitglied fortgesetzt und veröffentlicht werden; maßgeblich ist der Veröffentlicher, nicht der Ersteller.
  - L1: Deaktivierte, noch nicht gelöschte Nutzer dürfen nicht Owner werden (`active?` prüfen).
  - L7: Ein Test, dessen erwarteter Wert gleich dem Fallback ist (API-Key des ältesten Admins), kann nicht rot werden; Testnutzer muss vom Fallback abweichen.

- **26.10.2026, L4/L8 (Fork #192, upstream issue 3039):** Erster Ansatz übernahm eine unowned Holding vor dem Save per `update_columns` (zweiter Schreibweg). Review fand: Validierungen (negatives qty) und Übertrag der Vortags-Korrekturen (Remap, gesperrter Einstandswert) fielen weg, DB-Fehler wurden ohne Savepoint verschluckt. Lösung: Lookup so erweitern, dass die Zeile in den normalen validierten Save-Weg läuft. Prüffrage: Baut ein Fix gegen Unique-Kollisionen einen zweiten Schreibweg neben `save!`? Dann lieber die Suche korrigieren, die die Zeile verpasst.

- **26.10.2026, Fork PR 194 (Regelliste schneller), /code-review vor PR, 3 Befunde behoben (e11594a):**
  - L12: Eine Memoisierung pro Objekt braucht einen Reset bei `reload`, sonst liefert ein langlebiges Objekt alte Labels. Prüffrage: Wird jeder neue Memo-Cache bei `reload` geleert?
  - L1: `min_by(&:id)` auf einer geladenen Assoziation scheitert an ungespeicherten Einträgen (id nil); `actions.first` ignorierte sie. Prüffrage: Kann die geladene Sammlung neue Datensätze enthalten?
  - Tempo: Bei `a || b` die billige In-Memory-Prüfung zuerst, sonst baut jede Zeile teure Provider-Objekte.
- **26.10.2026, Fork PR 195 (Bestände: Kostenbasis-Editor lazy), /code-review vor PR, 2 Befunde behoben (df80f0e):**
  - Lazy Turbo-Frames in dieser App brauchen `refresh: :morph`, sonst setzt ein Morph-Refresh den geladenen Frame auf den Platzhalter zurück und Turbo lädt nicht neu. Prüffrage: Hat jeder neue `loading: :lazy`-Frame `refresh: :morph`?
  - Platzhalter mit Text (`entries/loading`) statt stummem Skelett, damit Screenreader „Laden“ hören.
- **26.10.2026, Fork PR 196 (Tags-Seite ohne N+1), /code-review vor PR, 2 Befunde behoben (4b7952c):**
  - L2: Neue Klassenmethoden, die IDs prüfen, nehmen die Familie und lesen über `family.transactions` (wie `Category.ids_with_transactions`), nicht über die globale Tabelle.
  - Partial-Locals mit Default wie beim Geschwister-Partial; `render collection` mit `locals` gibt diese auch an strikte Spacer-Partials weiter (Fehler „unknown local“).

- Nachtrag 26.10.2026 (Fork 197, Ladezeiten aller Seiten): /code-review max fand (1) zwei getrennte Prozess-Caches für dieselbe Aufgabe (alle Locale-Übersetzungen eines Keys) → ein gemeinsamer Helfer `LanguagesHelper.folded_translations`, eingefroren (L10, L14); (2) Kontozugriff von Hand nachgebaut statt `Current.user.accessible_accounts` → bestehenden Scope nutzen, damit spätere Änderungen greifen (L2); (3) Preload einer Assoziation, die immer gleich @holding.security ist → überflüssige Abfrage weg (L14); (4) Kommentar beschrieb den alten Code → aktuelles Verhalten beschreiben. Messlehre: Nach dem Laden von Demo-Daten erst `VACUUM ANALYZE`, sonst messen Planner-Fehlschätzungen (700 statt 12 ms) statt echter Hotspots.
- Nachtrag 26.10.2026 (Fork 198, Budget-Reservierungen gebündelt): /code-review max fand (1) Bündel-Abfrage schrieb vorhandene Scopes von Hand nach und filterte family_id nur auf der gejointen Tabelle → `RecurringTransaction.bills`/`due_between` nutzen und auf der indizierten Spalte der Haupttabelle filtern (L14); (2) veralteter Verweis-Kommentar in einer anderen Datei (paycheck_planner) → bei Verschiebungen per grep alle Kommentar-Verweise mitziehen; (3) viermal gleicher Test-Aufbau → Helfer. Vorsicht: `bc.budget = self` auf synthetischen Zeilen mit has_many_inversing (load_defaults ≥ 7) kann die Zeile in die has_many-Liste schieben. Vorbestehend, gemeldet: Bill-Reservierung im Budget nicht nach Kontozugriff gefiltert (L2).
  - Nachtrag 27.10. (Review-Job, fe37560): L7/L21: `Import#publish_later` bekam ein neues Schlüsselwort, die Unterklasse `SureImport` überschreibt die Methode aber ohne es; der Web-Publish eines Sure-Imports wäre mit ArgumentError (500) gescheitert. Der Controller-Test stubbte `publish_later` und konnte es nicht merken. Prüffrage: Bei jeder Signaturänderung `grep "def <methode>"` über alle Unterklassen; mindestens ein Test ruft den echten Weg ohne Stub.
- 27.10.2026 Wochenauswertung (149 Befunde; Upstream 123 in 25 PRs, Fork 9 in 5 PRs, Bugfix-Rückblick 17; Liste befunde-woche-2026-10-27.md; 58 durchgerutscht, keine neue Lektion; neuer Bot cubic-dev-ai):
  - L5 (Rolling Deploy, jetzt fünf Fälle): Läuft während und nach der Migration noch der alte Release (Worker nach Web, Rollback)? Liest er verschlüsselte Werte als Klartext, schreibt er gelöschte Spalten oder bereinigte Daten (PII, Kontonamen) zurück? Dann Spalten-Drop und einmalige Bereinigung in einen Folge-Release verschieben. (upstream PR 4336, 4339)
  - L1: Liefert `jsonb::text` den Wert gequotet (verschlüsselter Umschlag)? (upstream PR 4336) Erben Unterschlüssel eine Maskierung, die nur für den Elternschlüssel gilt? Ersetzt ein `gsub` ohne Wortgrenze auch Teile fremder Zahlen? (upstream PR 4339) Wird eine gelöschte Zeile als Erfolg zurückgegeben? (upstream PR 4468) Laufen AASM-Bang-Events durch Validierungen, die der Wiederherstellungsweg nicht erfüllt? (upstream PR 4469) Löscht eine Anfrage nur mit unbekannten Parametern gespeicherten Zustand? (upstream PR 4464) Wird ein eindeutiger Wert nach Wechsel eines Teilschlüssels (Währung) zum Duplikat? (upstream PR 3510) Sortiert `ORDER BY … DESC` in PostgreSQL NULL zuerst? (Fork 168) Ergibt ein jsonb-Operator auf einer nullable Spalte NULL, sodass `NOT` die Zeile ausschließt (COALESCE)? (Fork 148) Verwirft `blank?`/`strip` Werte aus reinen Leerzeichen, die Inhalt sind (Stream-Chunks)? (Bugfix 4515)
  - L2: Zählt ein Update ohne echte Änderung (gleicher Wert, gleiche Tags, leeres permitted-Hash) als Auslöser für Folgearbeit (Regeln, KI, Mails)? Vorher/Nachher-Schnappschuss vergleichen, an allen Schreibwegen. (upstream PR 4347, sechs Stellen) Wird ein neuer permitted-Parameter auch im Re-Render-/Rebuild-Weg entfernt? (upstream PR 3510) Ist ein Export-Import-Rundweg für Verweise auf Provider-Datensätze geprüft (ProviderMerchant vs. FamilyMerchant)? (Fork 156)
  - L4: Werden Wert und zugehöriges Sperr-Flag in einem Schritt gespeichert? (upstream PR 4340) Ist vor der Sperre memoisierter Zustand nach dem Warten noch gültig (neu laden)? Wartet eine Sperre mit offener äußerer Transaktion? (upstream PR 4465) Wird bei RecordNotUnique geprüft, welcher Index verletzt ist? (upstream PR 3510) Bleiben Löschen und Neuaufbau-Einplanung atomar? (upstream PR 4474) Bricht ein Client-`abort` nur die Antwort ab, während der Server weiterschreibt (serialisieren)? (upstream PR 4347)
  - L8: Wird nach einem Fehler erneut versucht, obwohl der Commit schon durch ist (Retry verpufft)? (upstream PR 4469) Löst ein Fehler nach erledigter Arbeit (Broadcast) einen Retry der teuren Arbeit aus? Gilt ein Login-Redirect mit 200 als Erfolg? Wird erst nach Ende asynchroner Kind-Jobs aktualisiert? (upstream PR 4347) Liefert ein fremder Lock still 0 statt eines Hinweises? (upstream PR 4474)
  - L9: Enthält der Cache-Key jede Eingabe, die das Markup umschaltet (Subtyp über supports_trades?, Übersetzungsdateien)? (upstream PR 4475) Überschreibt ein Hash mit gleichem Schlüssel still, statt die Kollision zu erkennen? (upstream PR 4344) Ändert sich Last-Modified bei jeder Änderung, die die Antwort beeinflusst (Rechte), sonst nur ETag? (Fork 165)
  - L6: Bleibt ein halb fertiger Bedienzustand (gegriffene Zeile per Tastatur/Touch) bei Morph-Refresh und Wegnavigieren erhalten? (upstream PR 4341) Zeigt das Formular nach einem Fehler den gespeicherten statt den eingegebenen Zustand (`*_in_database`)? (upstream PR 3510)
  - L3/L25: Fließen Namen nicht zugänglicher Datensätze in abgeleiteten Text (Suchattribut, data-*)? (upstream PR 4466) Kann ein Nur-Lesen-Mitglied über ein leeres Update kostenpflichtige Aktionen auslösen? (upstream PR 4347) `encrypts` ohne `support_unencrypted_data` bei Klartext-Altzeilen? (upstream PR 3510)
  - L33: Wird die Blank-Prüfung auf den normalisierten Wert angewendet („-“ wird nil und löscht)? (upstream PR 3510) Leeres Passwort: liefert `update` true, ohne den Digest zu ändern? (upstream PR 4191)
  - L14: Hält eine Warteschleife eine DB-Verbindung? (upstream PR 4465) Läuft ein teurer Scope (Regex) vor dem einschränkenden ID-Filter? (upstream PR 4347)
  - L13: Stimmt jeder Hinweistext mit dem Code überein (versprochene Ausnahmen, Auswirkung auf geteilte Daten anderer Familien)? (upstream PR 4347, 4474)
  - L16/L18: Übernimmt eine Kreditkarte die IBAN des Abrechnungskontos? (upstream PR 3510) Ruft der Sync Produkte ohne Einwilligung ab? (Bugfix 4524) Läuft eine Aktion ohne Provider trotzdem zerstörerisch? (upstream PR 4474) Läuft ein in `after_initialize` gestarteter Thread bei Puma-Clustern auch in den Workern? (Fork 168) Hinweistexte ohne Dollar-Annahme. (upstream PR 3020)
  - L7: Läuft ein Test leer durch, wenn nichts geprüft wird (Zähler und Mindestanzahl)? (upstream PR 3510) Läuft der Test gegen den Store der Produktion (Redis statt Memory)? (Bugfix 4328)
  - L26/L27/L30/L31: Gibt das verwaiste Konto den Wert frei, bevor der neue ihn übernimmt? (upstream PR 3510) Erkennt eine Bereinigung fremde Daten gleicher Form? (upstream PR 4339) Wird beim Bearbeiten ein bestehender Wert außerhalb der Allowlist akzeptiert? (Fork 156) Zeitstempel in der Konto-Zeitzone geparst? (upstream PR 4344) Erweiterte Bedingungen treffen alte Ereignisse erneut? (Bugfix 4150) Händler-Ownership nach Wertkollision? (upstream PR 4467)
  - L5: Eindeutige Migrationsversion nach parallelen PRs? (Bugfix 4435)
  - Review-Prompt (Teil D): Alle durchgerutschten Befunde fallen unter vorhandene Lektionsfragen. Vorschlag für Teil A (nur nach Owner-Ok): bei Migrationen ausdrücklich „alter Release läuft parallel“ prüfen lassen.
  - L33 (Fork 201, 27.10.): Normalisiert eine zentrale Eingabe-Umwandlung "" oder `null` zu einem leeren Wert ([]), den ein zerstörerischer Empfänger als „alles ersetzen durch nichts“ liest (update_rule conditions "" löschte alle Bedingungen)? Leere und null-Werte unverändert durchreichen, damit die Validierung des Empfängers greift. Wird bei geglücktem JSON.parse der geparste Wert verworfen (Nicht-Array)?
  - L7 (Fork 201): `all?` auf einer leeren Ergebnisliste ist immer wahr; zusätzlich einen erwarteten Treffer prüfen.
  - L11 (Fork 202, 27.10.): Neuer UI-Key (`copied`) nur in en/de angelegt, obwohl alle 16 Locales den Nachbar-Key (`copy_button`) übersetzen; Nachbar-Key-Test in test/i18n_test.rb ergänzen.
  - L7 (Fork 202): Layout-Test prüfte nur `document.body.scrollWidth`; zusätzlich rechte Kanten von Inhalt und Button gegen den Container prüfen und alle betroffenen Zeilen (OIDC und SAML) abdecken.
  - L12 (Fork 202): Gleiche handgebaute Kopierzeile zweimal im Diff → gemeinsames Partial; DS::Button `:sm` mit Text ist nur 28 px hoch, Standardgröße nutzen.
