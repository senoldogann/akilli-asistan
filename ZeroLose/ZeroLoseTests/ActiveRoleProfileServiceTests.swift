import XCTest
@testable import ZeroLose

final class ActiveRoleProfileServiceTests: XCTestCase {
    private let loihdeDescription = """
    Loihde

    Etsimme kasvavaan Data, Digital & AI -yksikköömme kokenutta fullstack-ohjelmistokehittäjiä mielenkiintoisiin asiakastoimeksiantoihin.
    Toimistomme sijaitsevat Helsingissä, Lappeenrannassa sekä Oulussa. Voit työskennellä miltä tahansa näistä paikkakunnista hydridinä.

    Mitä odotamme sinulta:
    * Yli 5 vuoden kokemusta Node.js- tai Java (Spring framework) -pohjaisesta ohjelmistokehityksestä
    * Frontend-kokemusta käyttäen JavaScript (TypeScript) ja ReactJS-teknologioita
    * Kykyä suunnitella, ottaa käyttöön ja hallita pilvipohjaisia sovelluksia erityisesti Azure-ympäristössä
    * Kokemusta DevOps-käytännöistä ja CI/CD-putkien parissa työskentelystä
    * Kokemusta integraatioteknologioiden käytöstä, REST API:n luomisesta ja sovellusrajapintojen turvallisesta hyödyntämisestä
    * Kokemusta ohjelmistotuotantoprosessista ketterillä menetelmillä ja softa-automaatiosta
    * Hyviä vuorovaikutustaitoja sekä sujuvaa suomen ja englannin kielen osaamista
    * Rohkeutta ja näkemyksellisyyttä ratkaista asiakkaan liiketoiminnan haasteita
    * Omistajuutta ja vastuunottoa omasta tekemisestä
    * Kiinnostusta tai perehtyneisyyttä tekoälyn hyödyntämiseen ohjelmistokehityksessä

    Mitä voit odottaa meiltä:
    * Reilu ja kannustava, tehtävään perustuva palkkamalli
    * Mahdollisuus vaikuttaa omaan urakehitykseesi

    Miksi tulla Loihteelle?
    * Olemme ammattitaitoinen ja lämminhenkinen yhteisö, jossa jokaisella on tilaa olla oma itsensä
    * Tarjoamme resursseja ja joustavia mahdollisuuksia oman osaamisen kehittämiseen
    """

    func testProfileParsesCompanyRoleAndFocusAreas() {
        let profile = ActiveRoleProfileService.profile(from: loihdeDescription)

        XCTAssertNotNil(profile)
        XCTAssertEqual(profile?.company, "Loihde")
        XCTAssertTrue(profile?.roleTitle.localizedCaseInsensitiveContains("fullstack") == true)
        XCTAssertTrue(profile?.focusAreas.contains("Backend (Node.js / Java / Spring)") == true)
        XCTAssertTrue(profile?.focusAreas.contains("Cloud / Azure") == true)
        XCTAssertTrue(profile?.focusAreas.contains("DevOps / CI-CD") == true)
    }

    func testRelevantMatchesFindAzureCompetency() {
        guard let profile = ActiveRoleProfileService.profile(from: loihdeDescription) else {
            XCTFail("Profile should parse")
            return
        }

        let matches = ActiveRoleProfileService.relevantMatches(
            for: "Onko sinulla kokemusta Azuresta?",
            profile: profile,
            maxResults: 3
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.question, "Cloud / Azure")
        XCTAssertGreaterThan(matches.first?.score ?? 0, 0.22)
    }

    func testRelevantMatchesFindCompanyMotivation() {
        guard let profile = ActiveRoleProfileService.profile(from: loihdeDescription) else {
            XCTFail("Profile should parse")
            return
        }

        let matches = ActiveRoleProfileService.relevantMatches(
            for: "Miksi Loihde?",
            profile: profile,
            maxResults: 3
        )

        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.first?.record.question, "Why This Company")
    }

    func testGroundingContextIncludesCompanyAndRelevantEvidence() {
        guard let profile = ActiveRoleProfileService.profile(from: loihdeDescription) else {
            XCTFail("Profile should parse")
            return
        }

        let context = ActiveRoleProfileService.groundingContext(
            for: "Kerro Azure-kokemuksesta",
            profile: profile,
            maxResults: 2
        )

        XCTAssertTrue(context.contains("Company: Loihde"))
        XCTAssertTrue(context.contains("Cloud / Azure"))
        XCTAssertTrue(context.contains("ACTIVE ROLE GROUNDING"))
    }
}
