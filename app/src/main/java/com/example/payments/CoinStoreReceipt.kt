package com.example.payments

/**
 * Minimal marketplace-neutral receipt data. The app only forwards signed receipt material;
 * the server independently verifies the signature and owns all coin credit decisions.
 */
data class CoinStoreReceipt(
    val productId: String,
    val payload: String,
    val packageName: String,
    val originalJson: String,
    val dataSignature: String,
    val purchaseToken: String
)
