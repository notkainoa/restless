import Foundation

@objc protocol HelperProtocol {
    func ping(withReply reply: @escaping () -> Void)
    func setDisableSleep(_ enabled: Bool, withReply reply: @escaping (Bool) -> Void)
}
