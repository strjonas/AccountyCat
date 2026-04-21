//
//  StructuredOutputJSON.swift
//  ACShared
//
//  Created by Codex on 20.04.26.
//

import Foundation

enum StructuredOutputJSON {
    nonisolated static func jsonObjects(in text: String) -> [String] {
        var results: [(String.Index, String)] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "{" else {
                index = text.index(after: index)
                continue
            }

            if let object = jsonObject(in: text, startingAt: index) {
                results.append((index, object))
            }

            index = text.index(after: index)
        }

        var seen = Set<String>()
        var ordered: [String] = []
        for (_, object) in results {
            if seen.insert(object).inserted {
                ordered.append(object)
            }
        }
        return ordered
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from output: String) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for object in jsonObjects(in: output).reversed() {
            guard let data = object.data(using: .utf8),
                  let decoded = try? decoder.decode(type, from: data) else {
                continue
            }
            return decoded
        }

        return nil
    }

    nonisolated private static func jsonObject(
        in text: String,
        startingAt startIndex: String.Index
    ) -> String? {
        var currentIndex = startIndex
        var depth = 0
        var insideString = false
        var escaping = false

        while currentIndex < text.endIndex {
            let character = text[currentIndex]

            if insideString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    insideString = false
                }
                currentIndex = text.index(after: currentIndex)
                continue
            }

            if character == "\"" {
                insideString = true
                currentIndex = text.index(after: currentIndex)
                continue
            }

            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let endIndex = text.index(after: currentIndex)
                    return String(text[startIndex..<endIndex])
                }
            }

            currentIndex = text.index(after: currentIndex)
        }

        return nil
    }
}
