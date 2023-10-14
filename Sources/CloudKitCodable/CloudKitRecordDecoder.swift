//
//  CloudKitRecordDecoder.swift
//  CloudKitCodable
//
//  Created by Guilherme Rambo on 12/05/18.
//  Copyright © 2018 Guilherme Rambo. All rights reserved.
//

import Foundation
import CloudKit

final public class CloudKitRecordDecoder {
    public func decode<T>(_ type: T.Type, from record: CKRecord) throws -> T where T : Decodable {
        let decoder = _CloudKitRecordDecoder(record: record)
        return try T(from: decoder)
    }

    public init() { }
}

final class _CloudKitRecordDecoder {
    var codingPath: [CodingKey] = []

    var userInfo: [CodingUserInfoKey : Any] = [:]

    var container: CloudKitRecordDecodingContainer?
    fileprivate var record: CKRecord

    init(record: CKRecord) {
        self.record = record
    }
}

extension _CloudKitRecordDecoder: Decoder {
    fileprivate func assertCanCreateContainer() {
        precondition(self.container == nil)
    }

    func container<Key>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> where Key : CodingKey {
        assertCanCreateContainer()

        let container = KeyedContainer<Key>(record: self.record, codingPath: self.codingPath, userInfo: self.userInfo)
        self.container = container

        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedDecodingContainer {
        fatalError("Not implemented")
    }

    func singleValueContainer() -> SingleValueDecodingContainer {
        fatalError("Not implemented")
    }
}

protocol CloudKitRecordDecodingContainer: AnyObject {
    var codingPath: [CodingKey] { get set }

    var userInfo: [CodingUserInfoKey : Any] { get }

    var record: CKRecord { get set }
}

extension _CloudKitRecordDecoder {
    final class KeyedContainer<Key> where Key: CodingKey {
        var record: CKRecord
        var codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any]

        private lazy var systemFieldsData: Data = {
            return decodeSystemFields()
        }()

        func nestedCodingPath(forKey key: CodingKey) -> [CodingKey] {
            return self.codingPath + [key]
        }

        init(record: CKRecord, codingPath: [CodingKey], userInfo: [CodingUserInfoKey : Any]) {
            self.codingPath = codingPath
            self.userInfo = userInfo
            self.record = record
        }

        func checkCanDecodeValue(forKey key: Key) throws {
            guard self.contains(key) else {
                let context = DecodingError.Context(codingPath: self.codingPath, debugDescription: "key not found: \(key)")
                throw DecodingError.keyNotFound(key, context)
            }
        }
    }
}

extension _CloudKitRecordDecoder.KeyedContainer: KeyedDecodingContainerProtocol {
    var allKeys: [Key] {
        return self.record.allKeys().compactMap { Key(stringValue: $0) }
    }

    func contains(_ key: Key) -> Bool {
        guard key.stringValue != _CKSystemFieldsKeyName else { return true }

        return allKeys.contains(where: { $0.stringValue == key.stringValue })
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        try checkCanDecodeValue(forKey: key)

        if key.stringValue == _CKSystemFieldsKeyName {
            return systemFieldsData.count == 0
        } else {
            return record[key.stringValue] == nil
        }
    }

    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T : Decodable {
        try checkCanDecodeValue(forKey: key)

        print("decode key: \(key.stringValue)")

        if key.stringValue == _CKSystemFieldsKeyName {
            return systemFieldsData as! T
        }

        if key.stringValue == _CKIdentifierKeyName {
            return record.recordID.recordName as! T
        }

        // Bools are encoded as Int64 in CloudKit
        if type == Bool.self {
            return try decodeBool(forKey: key) as! T
        }

        // URLs are encoded as String (remote) or CKAsset (file URL) in CloudKit
        if type == URL.self {
            return try decodeURL(forKey: key) as! T
        }

        func typeMismatch(_ message: String) -> DecodingError {
            let context = DecodingError.Context(
                codingPath: codingPath,
                debugDescription: message
            )
            return DecodingError.typeMismatch(type, context)
        }

        if let stringEnumType = T.self as? any CloudKitStringEnum.Type {
            guard let stringValue = record[key.stringValue] as? String else {
                throw typeMismatch("Expected to decode a rawValue String for \"\(String(describing: type))\"")
            }
            guard let enumValue = stringEnumType.init(rawValue: stringValue) ?? stringEnumType.cloudKitFallbackCase else {
                #if DEBUG
                throw typeMismatch("Failed to construct enum \"\(String(describing: type))\" from String \"\(stringValue)\"")
                #else
                throw typeMismatch("Failed to construct enum \"\(String(describing: type))\" from String value")
                #endif
            }
            return enumValue as! T
        }

        if let intEnumType = T.self as? any CloudKitIntEnum.Type {
            guard let intValue = record[key.stringValue] as? Int else {
                throw typeMismatch("Expected to decode a rawValue Int for \"\(String(describing: type))\"")
            }
            guard let enumValue = intEnumType.init(rawValue: intValue) ?? intEnumType.cloudKitFallbackCase else {
                throw typeMismatch("Failed to construct enum \"\(String(describing: type))\" from value \"\(intValue)\"")
            }
            return enumValue as! T
        }

        guard let value = record[key.stringValue] as? T else {
            throw typeMismatch("CKRecordValue couldn't be converted to \"\(String(describing: type))\"")
        }

        return value
    }

    private func decodeURL(forKey key: Key) throws -> URL {
        if let asset = record[key.stringValue] as? CKAsset {
            return try decodeURL(from: asset)
        }

        guard let str = record[key.stringValue] as? String else {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "URL should have been encoded as String in CKRecord")
            throw DecodingError.typeMismatch(URL.self, context)
        }

        guard let url = URL(string: str) else {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "The string \(str) is not a valid URL")
            throw DecodingError.typeMismatch(URL.self, context)
        }

        return url
    }

    private func decodeURL(from asset: CKAsset) throws -> URL {
        guard let url = asset.fileURL else {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "URL value not found")
            throw DecodingError.valueNotFound(URL.self, context)
        }

        return url
    }

    private func decodeBool(forKey key: Key) throws -> Bool {
        guard let intValue = record[key.stringValue] as? Int64 else {
            let context = DecodingError.Context(codingPath: codingPath, debugDescription: "Bool should have been encoded as Int64 in CKRecord")
            throw DecodingError.typeMismatch(Bool.self, context)
        }

        return intValue == 1
    }

    private func decodeSystemFields() -> Data {
        let coder = NSKeyedArchiver.init(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()

        return coder.encodedData
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        fatalError("Not implemented")
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey : CodingKey {
        fatalError("Not implemented")
    }

    func superDecoder() throws -> Decoder {
        return _CloudKitRecordDecoder(record: record)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        let decoder = _CloudKitRecordDecoder(record: self.record)
        decoder.codingPath = [key]

        return decoder
    }
}

extension _CloudKitRecordDecoder.KeyedContainer: CloudKitRecordDecodingContainer {}
