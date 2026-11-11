// Prints the Sparkle EdDSA public key for the private seed on stdin (base64, as
// generate_keys -x writes it). release.yml compares it with the built app's
// SUPublicEDKey so a mismatched secret fails the release instead of shipping a
// feed no installed copy can verify (D-011).
import CryptoKit
import Foundation

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: input), seed.count == 32,
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
    FileHandle.standardError.write(Data("error: not a 32-byte base64 EdDSA seed\n".utf8))
    exit(1)
}
print(key.publicKey.rawRepresentation.base64EncodedString())
