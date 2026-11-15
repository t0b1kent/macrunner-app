import CryptoKit
import Foundation
import Security

/// GOTHIC3 07.11.2026 — D3DX-A step 2 (0003): check the Authenticode signature EMBEDDED in a PE file
/// (security data directory → WIN_CERTIFICATE → PKCS#7 SignedData with SpcIndirectDataContent).
///
/// ★ Why our own code: Security's CMSDecoder refuses Authenticode blobs (measured 07.11: CMSDecoderUpdateMessage
///   -25257 on the real d3dx9_40.dll signature) — PKCS#7 v1.5 carries the content as a SEQUENCE, not an OCTET STRING.
///
/// What is verified, all three must hold:
///   1. the image digest (Authenticode PE hash: whole file minus CheckSum, the security directory entry and the
///      certificate table) equals the digest inside the signed SpcIndirectDataContent;
///   2. the signer's `messageDigest` attribute equals the hash of that content;
///   3. the RSA signature over the authenticated attributes verifies with the public key of the embedded
///      certificate whose serial number the SignerInfo names.
/// NOT verified: the certificate chain to a trusted root (the 1997 «Microsoft Root Authority» is not in the macOS
/// trust store and long expired). Who the publisher is, is pinned separately (`GameRedist.microsoftReleases`).
enum Authenticode {
    struct Signature: Sendable, Equatable {
        let signerCommonName: String?
        let signerOrganization: String?
        /// "sha1" or "sha256" — the image digest algorithm.
        let digestAlgorithm: String
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notPE
        case noSignature
        case malformed(String)
        case unsupported(String)
        case imageDigestMismatch
        case contentDigestMismatch
        case signerNotFound
        case badSignature

        var description: String {
            switch self {
            case .notPE: return "not a PE file"
            case .noSignature: return "no embedded signature"
            case .malformed(let what): return "malformed signature (\(what))"
            case .unsupported(let what): return "unsupported signature (\(what))"
            case .imageDigestMismatch: return "file does not match its signature"
            case .contentDigestMismatch: return "signed attributes do not match the signed content"
            case .signerNotFound: return "signer certificate missing"
            case .badSignature: return "signature does not verify"
            }
        }
    }

    // MARK: - DER

    private struct Element {
        let tag: UInt8
        let start: Int
        let valueStart: Int
        let end: Int
        var value: Range<Int> { valueStart..<end }
        var whole: Range<Int> { start..<end }
    }

    private static func element(_ b: [UInt8], at i: Int, limit: Int) throws -> Element {
        guard i + 2 <= limit else { throw Failure.malformed("truncated header") }
        let tag = b[i]
        let first = Int(b[i + 1])
        var length = 0, header = 2
        if first < 0x80 {
            length = first
        } else {
            let count = first & 0x7f
            // DER only: no indefinite length, at most 4 length octets.
            guard (1...4).contains(count), i + 2 + count <= limit else { throw Failure.malformed("length") }
            for k in 0..<count { length = length << 8 | Int(b[i + 2 + k]) }
            header += count
        }
        guard length >= 0, i + header + length <= limit else { throw Failure.malformed("element overruns its parent") }
        return Element(tag: tag, start: i, valueStart: i + header, end: i + header + length)
    }

    private static func children(_ b: [UInt8], _ e: Element) throws -> [Element] {
        var out: [Element] = []
        var i = e.valueStart
        while i < e.end {
            let child = try element(b, at: i, limit: e.end)
            out.append(child)
            i = child.end
        }
        return out
    }

    private static func expect(_ e: Element, _ tag: UInt8, _ what: String) throws {
        guard e.tag == tag else { throw Failure.malformed(what) }
    }

    // OID value bytes
    private static let oidSignedData: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
    private static let oidSpcIndirectData: [UInt8] = [0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x04]
    private static let oidMessageDigest: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04]
    private static let oidSHA1: [UInt8] = [0x2B, 0x0E, 0x03, 0x02, 0x1A]
    private static let oidSHA256: [UInt8] = [0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01]
    private static let oidCommonName: [UInt8] = [0x55, 0x04, 0x03]
    private static let oidOrganization: [UInt8] = [0x55, 0x04, 0x0A]

    private static func algorithm(_ b: [UInt8], _ identifier: Element) throws -> String {
        try expect(identifier, 0x30, "algorithm identifier")
        guard let oid = try children(b, identifier).first, oid.tag == 0x06 else { throw Failure.malformed("algorithm oid") }
        let value = Array(b[oid.value])
        if value == oidSHA1 { return "sha1" }
        if value == oidSHA256 { return "sha256" }
        throw Failure.unsupported("digest algorithm")
    }

    private static func hash(_ algorithm: String, _ parts: [ArraySlice<UInt8>]) -> [UInt8] {
        if algorithm == "sha1" {
            var h = Insecure.SHA1()
            for p in parts { p.withUnsafeBytes { h.update(bufferPointer: $0) } }
            return Array(h.finalize())
        }
        var h = SHA256()
        for p in parts { p.withUnsafeBytes { h.update(bufferPointer: $0) } }
        return Array(h.finalize())
    }

    // MARK: - PE

    private static func u16(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= b.count else { throw Failure.notPE }
        return Int(b[o]) | Int(b[o + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ o: Int) throws -> Int {
        guard o >= 0, o + 4 <= b.count else { throw Failure.notPE }
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    /// Where the hashed regions and the PKCS#7 blob are.
    private struct Layout {
        let checksum: Int
        let securityEntry: Int
        let certificates: Range<Int>
        let pkcs7: Range<Int>
    }

    private static func layout(_ b: [UInt8]) throws -> Layout {
        guard b.count > 0x40, b[0] == 0x4D, b[1] == 0x5A else { throw Failure.notPE }
        let pe = try u32(b, 0x3C)
        guard pe + 24 <= b.count, b[pe] == 0x50, b[pe + 1] == 0x45, b[pe + 2] == 0, b[pe + 3] == 0 else { throw Failure.notPE }
        let optional = pe + 24
        let magic = try u16(b, optional)
        guard magic == 0x10b || magic == 0x20b else { throw Failure.notPE }
        let count = try u32(b, optional + (magic == 0x10b ? 92 : 108))
        guard count > 4 else { throw Failure.noSignature }
        let securityEntry = optional + (magic == 0x10b ? 96 : 112) + 4 * 8
        // The security directory holds a FILE offset, not an RVA.
        let offset = try u32(b, securityEntry), size = try u32(b, securityEntry + 4)
        guard size > 8 else { throw Failure.noSignature }
        guard offset >= securityEntry + 8, offset + size <= b.count else { throw Failure.malformed("certificate table bounds") }
        let length = try u32(b, offset), revision = try u16(b, offset + 4), type = try u16(b, offset + 6)
        guard revision == 0x0200, type == 0x0002, length > 8, length <= size else {
            throw Failure.unsupported("WIN_CERTIFICATE revision \(revision) type \(type)")
        }
        return Layout(checksum: optional + 64, securityEntry: securityEntry,
                      certificates: offset..<(offset + size), pkcs7: (offset + 8)..<(offset + length))
    }

    // MARK: - Verification

    static func verify(_ data: Data) throws -> Signature {
        let b = [UInt8](data)
        let place = try layout(b)
        let limit = place.pkcs7.upperBound
        let contentInfo = try element(b, at: place.pkcs7.lowerBound, limit: limit)
        try expect(contentInfo, 0x30, "ContentInfo")
        let outer = try children(b, contentInfo)
        guard outer.count == 2, outer[0].tag == 0x06, Array(b[outer[0].value]) == oidSignedData, outer[1].tag == 0xA0,
              let signedData = try children(b, outer[1]).first else { throw Failure.malformed("not SignedData") }
        try expect(signedData, 0x30, "SignedData")
        let parts = try children(b, signedData)
        // version, digestAlgorithms, contentInfo, [0] certificates, [1] crls?, signerInfos
        guard parts.count >= 4, parts[0].tag == 0x02, parts[1].tag == 0x31, parts[2].tag == 0x30,
              let signerInfos = parts.last, signerInfos.tag == 0x31,
              let certificateSet = parts.first(where: { $0.tag == 0xA0 }) else { throw Failure.malformed("SignedData fields") }

        // Signed content: SpcIndirectDataContent { data, DigestInfo { algorithm, digest } }.
        let inner = try children(b, parts[2])
        guard inner.count == 2, inner[0].tag == 0x06, Array(b[inner[0].value]) == oidSpcIndirectData, inner[1].tag == 0xA0,
              let content = try children(b, inner[1]).first else { throw Failure.malformed("not SpcIndirectDataContent") }
        try expect(content, 0x30, "SpcIndirectDataContent")
        let contentParts = try children(b, content)
        guard contentParts.count == 2 else { throw Failure.malformed("SpcIndirectDataContent fields") }
        let digestInfo = try children(b, contentParts[1])
        guard digestInfo.count == 2, digestInfo[1].tag == 0x04 else { throw Failure.malformed("DigestInfo") }
        let imageAlgorithm = try algorithm(b, digestInfo[0])
        let signedImageDigest = Array(b[digestInfo[1].value])

        // 1. Image digest.
        var regions: [ArraySlice<UInt8>] = [b[0..<place.checksum], b[(place.checksum + 4)..<place.securityEntry],
                                            b[(place.securityEntry + 8)..<place.certificates.lowerBound]]
        if place.certificates.upperBound < b.count { regions.append(b[place.certificates.upperBound...]) }
        guard hash(imageAlgorithm, regions) == signedImageDigest else { throw Failure.imageDigestMismatch }

        // 2. First signer: version, issuerAndSerial, digestAlgorithm, [0] authenticated attributes, encAlg, signature.
        guard let signer = try children(b, signerInfos).first else { throw Failure.malformed("no SignerInfo") }
        let fields = try children(b, signer)
        guard fields.count >= 6, fields[1].tag == 0x30, fields[3].tag == 0xA0, fields[5].tag == 0x04 else {
            throw Failure.malformed("SignerInfo fields")
        }
        let issuerAndSerial = try children(b, fields[1])
        guard issuerAndSerial.count == 2, issuerAndSerial[1].tag == 0x02 else { throw Failure.malformed("issuerAndSerialNumber") }
        let serial = Array(b[issuerAndSerial[1].value])
        let signerAlgorithm = try algorithm(b, fields[2])
        var attributeDigest: [UInt8]? = nil
        for attribute in try children(b, fields[3]) {
            let pair = try children(b, attribute)
            guard pair.count == 2, pair[0].tag == 0x06 else { continue }
            if Array(b[pair[0].value]) == oidMessageDigest, let octets = try children(b, pair[1]).first, octets.tag == 0x04 {
                attributeDigest = Array(b[octets.value])
            }
        }
        // PKCS#7 v1.5: the digest covers the content octets of the content (without its own tag and length).
        guard let attributeDigest, attributeDigest == hash(signerAlgorithm, [b[content.value]]) else {
            throw Failure.contentDigestMismatch
        }

        // 3. Signature over the authenticated attributes, DER-encoded as a SET (tag 0x31 instead of [0]).
        var signed = Array(b[fields[3].whole])
        signed[0] = 0x31
        let signature = Data(b[fields[5].value])
        let keyAlgorithm: SecKeyAlgorithm = signerAlgorithm == "sha1"
            ? .rsaSignatureMessagePKCS1v15SHA1 : .rsaSignatureMessagePKCS1v15SHA256
        var matched = false
        for certificate in try children(b, certificateSet) where certificate.tag == 0x30 {
            let der = Data(b[certificate.whole])
            guard let cert = SecCertificateCreateWithData(nil, der as CFData),
                  let number = SecCertificateCopySerialNumberData(cert, nil) as Data?,
                  Self.sameSerial([UInt8](number), serial) else { continue }
            matched = true
            guard let key = SecCertificateCopyKey(cert),
                  SecKeyVerifySignature(key, keyAlgorithm, Data(signed) as CFData, signature as CFData, nil) else { continue }
            let names = try subjectNames(b, certificate)
            return Signature(signerCommonName: names.commonName, signerOrganization: names.organization,
                             digestAlgorithm: imageAlgorithm)
        }
        throw matched ? Failure.badSignature : Failure.signerNotFound
    }

    /// DER INTEGER bytes may carry a leading zero that Security drops (or keeps); compare the magnitude.
    private static func sameSerial(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        Array(a.drop { $0 == 0 }) == Array(b.drop { $0 == 0 })
    }

    /// CN and O of the certificate's subject: TBSCertificate { [0] version?, serial, signature, issuer, validity, subject, … }.
    private static func subjectNames(_ b: [UInt8], _ certificate: Element) throws -> (commonName: String?, organization: String?) {
        guard let tbs = try children(b, certificate).first else { throw Failure.malformed("certificate") }
        var fields = try children(b, tbs)
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        guard fields.count >= 5 else { throw Failure.malformed("TBSCertificate") }
        var commonName: String?, organization: String?
        for rdn in try children(b, fields[4]) {
            for pair in try children(b, rdn) {
                let typeAndValue = try children(b, pair)
                guard typeAndValue.count == 2, typeAndValue[0].tag == 0x06 else { continue }
                let oid = Array(b[typeAndValue[0].value])
                let raw = Array(b[typeAndValue[1].value])
                let text: String?
                switch typeAndValue[1].tag {
                case 0x1E: // BMPString, UTF-16BE
                    text = String(data: Data(raw), encoding: .utf16BigEndian)
                default:   // PrintableString, UTF8String, IA5String, T61String
                    text = String(decoding: raw, as: UTF8.self)
                }
                if oid == oidCommonName { commonName = text }
                if oid == oidOrganization { organization = text }
            }
        }
        return (commonName, organization)
    }
}
