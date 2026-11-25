import XCTest

final class VocabularyTests: XCTestCase {
    func testParsesTermsRulesCommentsAndBlankLines() {
        let vocabulary = Vocabulary(text: """
        # Fachbegriffe
        DATEV
          Belegfreigabe  \n
        Dann-Kriterien → Done-Kriterien
        DATIF -> DATEV

        """)
        XCTAssertEqual(vocabulary.terms, ["DATEV", "Belegfreigabe", "Done-Kriterien"], "right-hand sides are terms too, no duplicates")
        XCTAssertEqual(vocabulary.replacements, [
            .init(wrong: "Dann-Kriterien", right: "Done-Kriterien"),
            .init(wrong: "DATIF", right: "DATEV"),
        ])
    }

    func testPromptListsTheTermsAndIsCapped() {
        XCTAssertNil(Vocabulary(text: "# only a comment").prompt)
        XCTAssertEqual(Vocabulary(text: "DATEV\nADDISON").prompt, "Glossar: DATEV, ADDISON.")
        let long = Vocabulary(text: (1...300).map { "Begriff\($0)" }.joined(separator: "\n"))
        XCTAssertLessThanOrEqual(long.prompt?.count ?? 0, Vocabulary.maxPromptCharacters)
        XCTAssertTrue(long.prompt?.hasPrefix("Glossar: Begriff1, Begriff2") == true, "earlier lines win")
    }

    func testRulesReplaceWholeWordsCaseInsensitively() {
        let vocabulary = Vocabulary(text: "Dann-Kriterien → Done-Kriterien\nDATIF → DATEV")
        XCTAssertEqual(vocabulary.apply(to: "Die dann-Kriterien stehen, Export aus DATIF."), "Die Done-Kriterien stehen, Export aus DATEV.")
        XCTAssertEqual(vocabulary.apply(to: "Dannenberg und DATIFS"), "Dannenberg und DATIFS", "never inside another word")
    }

    func testAcronymAndCamelCaseTermsGetTheirSpelling() {
        let vocabulary = Vocabulary(text: "ADDISON\nDATEV\nWhisperStorm\nDone\nMandant")
        XCTAssertEqual(vocabulary.apply(to: "In Addison und im Datev-Export, Whisperstorm läuft."), "In ADDISON und im DATEV-Export, WhisperStorm läuft.")
        XCTAssertEqual(vocabulary.apply(to: "I'm done, der mandant zahlt."), "I'm done, der mandant zahlt.", "ordinary words keep their case")
    }

    func testReplacementTextIsLiteral() {
        let vocabulary = Vocabulary(text: "Euro → $1 €")
        XCTAssertEqual(vocabulary.apply(to: "zehn Euro"), "zehn $1 €")
    }

    func testDefaultListContainsHapesTerms() {
        let vocabulary = Vocabulary(text: Vocabulary.defaultText)
        for term in ["DATEV", "ADDISON", "Belegfreigabe", "Mandant", "Umsatzsteuervoranmeldung", "Done-Kriterien",
                     "Orkumo", "MAGOS", "TapeStorm", "WhisperStorm", "Codex", "Claude"] {
            XCTAssertTrue(vocabulary.terms.contains(term), term)
        }
        XCTAssertTrue(vocabulary.replacements.contains(.init(wrong: "Dann-Kriterien", right: "Done-Kriterien")))
    }
}
