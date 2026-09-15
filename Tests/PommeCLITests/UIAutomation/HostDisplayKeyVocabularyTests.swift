import AppKit
import Foundation
import Testing

@Suite("Host display key vocabulary")
struct HostDisplayKeyVocabularyTests {
    @Test("Every listed name and alias resolves to the same key")
    func namedKeysResolve() {
        for named in HostDisplayKey.namedKeys {
            let canonical = HostDisplayKey.lookup(named.name)
            #expect(canonical?.keyCode == named.keyCode, Comment(rawValue: named.name))
            #expect(canonical?.modifiers == named.modifiers, Comment(rawValue: named.name))
            for alias in named.aliases {
                #expect(HostDisplayKey.lookup(alias)?.keyCode == named.keyCode, Comment(rawValue: alias))
            }
        }
    }

    @Test("Every modifier prefix and alias adds its flag to a base key")
    func modifierPrefixesResolve() {
        for modifier in HostDisplayKey.modifierPrefixes {
            for prefix in modifier.prefixes {
                let key = HostDisplayKey.lookup(prefix + "a")
                #expect(key?.modifiers.contains(modifier.flag) == true, Comment(rawValue: prefix))
                #expect(key?.keyCode == HostDisplayKey.lookup("a")?.keyCode, Comment(rawValue: prefix))
            }
        }
    }

    @Test("Names are unique, plus is a separator, and unknown names are rejected")
    func vocabularyShape() {
        let names = HostDisplayKey.namedKeys.flatMap(\.names)
        #expect(Set(names).count == names.count)
        #expect(HostDisplayKey.lookup("cmd+shift+t")?.inputEventPlan == HostDisplayKey.lookup("cmd-shift-t")?.inputEventPlan)
        #expect(HostDisplayKey.lookup("Return")?.keyCode == 36)
        #expect(HostDisplayKey.lookup("bogus-key") == nil)
        #expect(HostDisplayKey.lookup("shift") == nil)
    }
}
