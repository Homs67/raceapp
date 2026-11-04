//
//  ObdProtocolName.swift
//  raceApp
//
//  ELM327 "ATDPN" answers are a single hex digit. This turns one into
//  something a driver can read.
//

import Foundation

enum ObdProtocolName {

    /// `ATDPN` returns the protocol number, optionally prefixed with "A" when
    /// the adapter searched for it rather than being pinned. The prefix tells
    /// us nothing the driver needs, so it is dropped.
    static func short(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let digit = trimmed.last, trimmed.allSatisfy({ $0.isHexDigit || $0 == "A" }) else {
            return nil
        }
        switch digit {
        case "1": return "J1850 PWM"
        case "2": return "J1850 VPW"
        case "3": return "ISO 9141-2"
        case "4": return "KWP slow init"
        case "5": return "KWP fast init"
        case "6": return "CAN 11/500"
        case "7": return "CAN 29/500"
        case "8": return "CAN 11/250"
        case "9": return "CAN 29/250"
        case "A": return "J1939 CAN"
        case "B": return "User CAN 1"
        case "C": return "User CAN 2"
        default: return nil     // "0" is "searching", which is not an answer
        }
    }
}
