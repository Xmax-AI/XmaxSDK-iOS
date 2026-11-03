//
//  XmaxCreditBalance.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-iOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

/// The server-reported credit balance for the account owning the client's API key.
public struct XmaxCreditBalance: Equatable, Sendable {

    /// Remaining credits as a finite, nonnegative value, including fractional credits.
    public let currentBalance: Double

    /// Creates a balance after the API payload has been validated.
    init(
        currentBalance: Double
    ) {
        self.currentBalance = currentBalance
    }
}
