# TintKing Calculator v1.2

macOS SwiftUI/Xcode-project voor calculaties van montagewerk op locatie.

## Nieuw in v1.2
- Calculaties lokaal opslaan op de Mac
- Opgeslagen calculaties terughalen vanuit de projectenlijst
- Zoeken op klant/projectnaam
- Project dupliceren
- Project verwijderen
- Cmd+S om snel op te slaan
- Datum laatste wijziging
- Berekende richtprijs zichtbaar in de projectenlijst
- Offertetekst gebruikt jouw gekozen verkoopprijs als je die hebt ingevuld

## Openen
1. Pak de zip uit.
2. Open `TintKingCalculator.xcodeproj` in Xcode.
3. Kies bovenin `My Mac`.
4. Klik op Run (▶︎).

## Waar worden projecten bewaard?
De projecten worden lokaal opgeslagen in de Application Support-map van macOS als JSON-bestand. Daardoor blijven ze beschikbaar nadat je de app afsluit en opnieuw opent.

## iCloud
Deze versie bewaart projecten lokaal. De opslagstructuur is bewust opgezet zodat een volgende versie naar CloudKit/iCloud kan worden uitgebreid voor Mac + iPhone synchronisatie.


## v1.3
- Flexibele inkoopregels met vrije omschrijving.
- Start standaard met één inkoopregel.
- Iedere nieuwe regel start op 40% opslag.
- Opslag per regel afzonderlijk instelbaar.
- Onbeperkt regels toevoegen met + en verwijderen met prullenbak.
- Totale inkoop, doorberekend materiaal en materiaalopbrengst zichtbaar.
- Alle inkoopregels worden samen met het project opgeslagen.


## v1.4
- Omschrijving van iedere inkoopregel is nu betrouwbaar bewerkbaar op macOS.
- De materiaalregels gebruiken index-gebaseerde bindings, zodat naam, inkoop en opslag direct wijzigen.
- Omschrijvingsveld heeft een duidelijk invoervak gekregen.


## v1.5
- Nieuwe tab Ramen tinten.
- Nieuwe tab Ontchromen.
- Ramen tinten werkt in 3 stappen: basispakket, extra/losse ruiten, totaal.
- Tintenprijzen overgenomen uit Prijslijst_TintKing_n8n.xlsx.
- Ontchromen heeft vrije samenstelling en voertuigpresets.
- Ontchroomprijzen en presets overgenomen uit Ontchroom_Prijslijst_n8n.xlsx.
- Presetprijzen kunnen per geselecteerd onderdeel handmatig worden aangepast.
- Beide calculators hebben een kopieerbare prijsopgave.


## v1.6
- Ontchromen: eigen presets opslaan.
- Standaard of eigen preset kopiëren en verder aanpassen.
- Eigen presets bijwerken en verwijderen.
- Vrije onderdelen met eigen naam en prijs toevoegen.
- Ramen tinten: basisprijs handmatig aanpassen.
- Ramen tinten: prijs per geselecteerd onderdeel handmatig aanpassen.
- Gewijzigde tintprijs kan met herstelknop terug naar standaard.


## v1.6.1
- Compilefout bij DechromeCalculatorView hersteld.
- De preset-alert staat nu correct als modifier binnen de body.


## v1.7
- Samenvatting Ramen tinten: geselecteerde extra onderdelen omhoog/omlaag rangschikken.
- Samenvatting Ontchromen: onderdelen omhoog/omlaag rangschikken.
- Nieuwe tab Aanvraag.
- Ramen tinten en Ontchromen kunnen aan dezelfde aanvraag worden toegevoegd.
- Toevoegen van dezelfde categorie vervangt de eerdere calculatie met de nieuwste prijs.
- Aanvraag toont subtotaal per categorie en één gecombineerd totaal.
- Volgorde Ramen tinten / Ontchromen in de aanvraag is aanpasbaar.
- Gecombineerde prijsopgave kan naar het klembord worden gekopieerd.


## v1.8
- Alle hoofdtotalen tonen inclusief én exclusief 21% btw.
- Ramen tinten en Ontchromen rekenen vanuit de bestaande consumentenprijzen incl. btw.
- Montagecalculator blijft rekenen vanuit excl. btw en toont daarnaast incl. btw.
- Korting kan als percentage of als vast eurobedrag worden ingevoerd.
- Korting beschikbaar bij Ramen tinten, Ontchromen, Montage en de gecombineerde Aanvraag.
- De gecombineerde prijsopgave toont subtotaal, korting, excl. btw, btw en incl. btw.


## v1.9
- In de gecombineerde aanvraag worden de btw-regels van Ramen tinten en Ontchromen niet meer herhaald.
- Per onderdeelgroep worden alleen werkzaamheden en subtotaal getoond.
- Nieuwe schakelaar 'Toon excl. btw en btw-bedrag'.
- Schakelaar uit: prijsopgave toont alleen het eindtotaal inclusief btw.
- Schakelaar aan: prijsopgave toont excl. btw, btw 21% en incl. btw.


## v2.0
- Nieuwe tab Rolcalculator.
- Snijplanner met max rolbreedte, onbeperkt regels, breedte en aantal.
- Toont gebruikt en resterend aantal centimeters.
- Waarschuwing wanneer de maximale rolbreedte wordt overschreden.
- Snijresultaat kopieerbaar naar klembord.
- Foliecalculator met rolbreedte, lengte per rol, aantal rollen en snijverlies.
- Berekent strekkende meters zonder verlies, met verlies en totaal oppervlak in m².
- Folieresultaat kopieerbaar en beide calculators hebben reset.


## v2.1 – visuele refresh
- Modernere kaartstijl met macOS materiaal, subtiele rand en schaduw.
- Groene TintKing accentkleur door de app.
- Rustigere achtergrondgradient.
- Nieuwe visuele koppen voor Rolcalculator en Aanvraag.
- Totaalprijs prominenter en compacter weergegeven.
- Bestaande berekeningen en gegevenslogica ongewijzigd.
