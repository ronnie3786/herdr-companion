import SwiftUI

struct RemoteNoteUpdateRequest: Encodable, Sendable {
    let expectedRevision: Int
    let changes: Changes

    struct Changes: Encodable, Sendable {
        let title: String
        let body: AttributedString

        private enum CodingKeys: String, CodingKey { case title, body, richBody }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(title, forKey: .title)
            try values.encode(String(body.characters), forKey: .body)
            try values.encode(body, forKey: .richBody, configuration: AttributeScopes.SwiftUIAttributes.self)
        }
    }
}
