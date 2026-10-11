import Testing

@testable import CruxCore

struct SearchQueryTests {
    private let docsetFilters: Set<String> = ["python", "django", "c++"]
    private let symbolTypes: Set<String> = ["class", "function", "method"]

    @Test
    func parsesKnownDocsetAndTypeFiltersCaseInsensitively() {
        let query = SearchQuery.parse(
            " Python, CLASS : string ",
            knownDocsetFilters: docsetFilters,
            knownSymbolTypes: symbolTypes
        )

        #expect(query.term == "string")
        #expect(query.docsetFilters == ["python"])
        #expect(query.symbolTypeFilters == ["class"])
    }

    @Test
    func parsesMultipleKnownDocsetFilters() {
        let query = SearchQuery.parse(
            "python,django:string",
            knownDocsetFilters: docsetFilters,
            knownSymbolTypes: symbolTypes
        )

        #expect(query.term == "string")
        #expect(query.docsetFilters == ["python", "django"])
        #expect(query.symbolTypeFilters.isEmpty)
    }

    @Test
    func preservesDoubleColonWhenPrefixIsNotARegisteredFilter() {
        let query = SearchQuery.parse(
            "std::string",
            knownDocsetFilters: docsetFilters,
            knownSymbolTypes: symbolTypes
        )

        #expect(query.term == "std::string")
        #expect(query.docsetFilters.isEmpty)
        #expect(query.symbolTypeFilters.isEmpty)
    }

    @Test
    func preservesWholeQueryWhenAnyPrefixTokenIsUnknown() {
        let query = SearchQuery.parse(
            "python,unknown:string",
            knownDocsetFilters: docsetFilters,
            knownSymbolTypes: symbolTypes
        )

        #expect(query.term == "python,unknown:string")
        #expect(query.docsetFilters.isEmpty)
    }

    @Test
    func acceptsAnEmptyTermForFilteredBrowsing() {
        let query = SearchQuery.parse(
            "python:",
            knownDocsetFilters: docsetFilters,
            knownSymbolTypes: symbolTypes
        )

        #expect(query.term.isEmpty)
        #expect(query.docsetFilters == ["python"])
    }
}
