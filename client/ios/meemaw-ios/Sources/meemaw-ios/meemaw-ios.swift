import Foundation
import Tsslib
import web3
import Security

public struct Wallet: EthereumAccountProtocol {
    public var address: EthereumAddress
    private var wallet: String
    private var server: String
    private var auth: String

    public init(wallet: String, address: String, server: String, auth: String) {
        self.address = EthereumAddress(address)
        self.wallet = wallet
        self.server = server
        self.auth = auth
    }
    
    public func From() -> EthereumAddress {
        return self.address
    }

    // SignEthTransaction signs an EthereumTransaction (from the Web3 library) using TSS
    public func SignEthTransaction(transaction: EthereumTransaction) throws -> SignedTransaction {
        return try sign(transaction: transaction)
    }

    // SignEthMessage signs an Ethereum message formatted as bytes (adding the Ethereum prefix)
    public func SignEthMessage(message: Data) throws -> String {
        return try signMessage(message: message)
    }

    // SignBytes signs hex encoded bytes using TSS
    public func SignBytes(message: Data) throws -> Data {
        return try sign(message: message)
    }
    
    // TssSign calls our Go TSS library and manages the error
    private func TssSign(message: Data) throws -> Data {
        let sig = TsslibSign(self.server, message, self.wallet, self.auth)
        
        if let signature = sig {
            if signature.successful {
                if let res = signature.result {
                    return res
                }
            } else {
                print("error when dkg:")
                print(signature.error)
            }
        }
        
        throw TssError.signError
    }
    
    // sign(message: Data, hashing: Bool) is a helper function for the EthereumAccountProtocol methods to use our TSS library
    private func sign(message: Data, hashing: Bool) throws -> Data {
        let msgData = hashing ? message.web3.keccak256 : message
        return try TssSign(message: msgData)
    }
    
    ////////////////////////
    /// EthereumAccountProtocol methods
    
    public func sign(data: Data) throws -> Data {
        return try sign(message: data, hashing: true)
    }

    public func sign(hex: String) throws -> Data {
        if let data = Data(hex: hex) {
            return try sign(message: data, hashing: true)
        } else {
            throw EthereumAccountError.signError
        }
    }

    public func sign(hash: String) throws -> Data {
        if let data = hash.web3.hexData {
            return try sign(message: data, hashing: false)
        } else {
            throw EthereumAccountError.signError
        }
    }

    public func sign(message: Data) throws -> Data {
        return try sign(message: message, hashing: false)
    }

    public func sign(message: String) throws -> Data {
        if let data = message.data(using: .utf8) {
            return try sign(message: data, hashing: true)
        } else {
            throw EthereumAccountError.signError
        }
    }

    public func signMessage(message: Data) throws -> String {
        let prefix = "\u{19}Ethereum Signed Message:\n\(String(message.count))"
        guard var data = prefix.data(using: .ascii) else {
            throw EthereumAccountError.signError
        }
        data.append(message)
        let hash = data.web3.keccak256

        guard var signed = try? sign(message: hash) else {
            throw EthereumAccountError.signError
        }

        // Check last char (v)
        guard var last = signed.popLast() else {
            throw EthereumAccountError.signError
        }

        if last < 27 {
            last += 27
        }

        signed.append(last)
        return signed.web3.hexString
    }

    public func signMessage(message: TypedData) throws -> String {
        let hash = try message.signableHash()

        guard var signed = try? sign(message: hash) else {
            throw EthereumAccountError.signError
        }

        // Check last char (v)
        guard var last = signed.popLast() else {
            throw EthereumAccountError.signError
        }

        if last < 27 { // Might need to change this ?
            last += 27
        }

        signed.append(last)
        return signed.web3.hexString
    }
    
    public func sign(transaction: EthereumTransaction) throws -> SignedTransaction {
        guard let raw = transaction.raw else {
            throw EthereumSignerError.emptyRawTransaction
        }

        guard let signature = try? sign(data: raw) else {
            throw EthereumSignerError.unknownError
        }

        return SignedTransaction(transaction: transaction, signature: signature)
    }
}

enum EthereumSignerError: Error {
    case emptyRawTransaction
    case unknownError
}

enum TssError: Error {
    case identifyError
    case dkgError
    case signError
}

public struct Meemaw {
    private var _server: String

    public init(server: String) {
        _server = server
    }
    
    // GetWallet returns the wallet if it exists or creates a new one
    public func GetWallet(auth: String) async throws -> Wallet {
        
        var dkgResult = ""
        
        // Get userId from authData
        let ret = TsslibIdentify(self._server, auth)
        var userId = ""
        
        if let userIdRet = ret {
            if userIdRet.successful {
                userId = userIdRet.result
            } else {
                print("error when identify:")
                print(userIdRet.error)
                throw TssError.identifyError
            }
        }

        if userId.isEmpty {
            throw TssError.identifyError
        }
        
        // 1. Try to get wallet from keychain
        do {
            dkgResult = try RetrieveWallet(userId: userId)
        } catch WalletStorageError.noWalletStored {
            // 2. If nothing stored : Dkg + store
            dkgResult = try dkg(auth: auth)
            try StoreWallet(dkgResult: dkgResult, userId: userId)
        } catch {
            print("Other error while retrieving wallet")
            throw error
        }
        
        // 3. return new wallet object with dkgResult (whether from new Dkg or previously stored)
        return Wallet(wallet: dkgResult, address: try GetAddressFromDkgResult(dkgResult: dkgResult), server: self._server, auth: auth)
        
    }
    
    private func dkg(auth: String) throws -> String {
        
        let ret = TsslibDkg(self._server, auth)

        if let dkg = ret {
            if dkg.successful {
                return dkg.result
            } else {
                print("error when dkg:")
                print(dkg.error)
            }
        }

        throw TssError.dkgError
    }
    
    enum WalletStorageError: Error {
        case noWalletStored
        case walletAlreadyStored
        case otherError
    }

    private func StoreWallet(dkgResult: String, userId: String) throws {       
        
        let keychainItem = [
          kSecValueData: dkgResult.data(using: .utf8)!,
          kSecAttrAccount: userId,
          kSecAttrServer: "getmeemaw.com",
          kSecClass: kSecClassInternetPassword
        ] as CFDictionary

        let status = SecItemAdd(keychainItem, nil)
        
        if status == errSecSuccess {
            return
        } else if status == errSecDuplicateItem {
            throw WalletStorageError.walletAlreadyStored
        } else {
            throw WalletStorageError.otherError
        }
    }

    private func RetrieveWallet(userId: String) throws -> String {
        
        let query = [
          kSecClass: kSecClassInternetPassword,
          kSecAttrAccount: userId,
          kSecAttrServer: "getmeemaw.com",
          kSecReturnAttributes: true,
          kSecReturnData: true
        ] as CFDictionary

        var result: AnyObject?
        let status = SecItemCopyMatching(query, &result)
        
        if status == errSecItemNotFound {
            print("item not found")
            throw WalletStorageError.noWalletStored
        } else if status != errSecSuccess {
            print("other error")
            throw WalletStorageError.otherError
        }

        let dic = result as! NSDictionary

        let dkgResultData = dic[kSecValueData] as! Data
        let dkgResult = String(data: dkgResultData, encoding: .utf8)!
        
        return dkgResult
    }
    
    private func GetAddressFromDkgResult(dkgResult: String) throws -> String {
        if let data = dkgResult.data(using: .utf8) {
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any], let address = json["Address"] as? String {
                    return address
                }
            } catch {
                print("Error parsing JSON: \(error)")
                throw error
            }
        }
        
        throw NSError(domain: NSCocoaErrorDomain, code: NSPropertyListReadCorruptError, userInfo: nil)
    }
}


