import CryptoKit
import Foundation

let privateKeyText = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard let secret = Data(base64Encoded: privateKeyText),
      secret.count == 32 || secret.count == 96 else {
    fputs("Sparkle private key must decode to Sparkle's 32-byte or legacy 96-byte format.\n", stderr)
    exit(1)
}

do {
    if secret.count == 96 {
        print(secret.suffix(32).base64EncodedString())
    } else {
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        print(privateKey.publicKey.rawRepresentation.base64EncodedString())
    }
} catch {
    fputs("Unable to derive Sparkle Ed25519 public key: \(error)\n", stderr)
    exit(1)
}
