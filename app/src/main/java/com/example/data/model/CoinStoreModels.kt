package com.example.data.model

enum class CoinStoreProvider(val id: String) {
    CAFEBAZAAR("cafebazaar"),
    MYKET("myket");

    companion object {
        fun fromId(value: String): CoinStoreProvider =
            values().firstOrNull { it.id == value }
                ?: throw IllegalStateException("Unsupported coin store provider: $value")
    }
}

/**
 * Product amounts/prices shown by the client. The server maintains its own private catalog
 * and never trusts these client values when crediting coins.
 */
data class CoinStoreProduct(
    val productId: String,
    val coinAmount: Long,
    val priceRial: Long
) {
    /** Display-only conversion: 10 Rial = 1 Toman. The server catalog remains authoritative. */
    val priceToman: Long
        get() = priceRial / 10L
    companion object {
        val all: List<CoinStoreProduct> = listOf(
            CoinStoreProduct("coins_5000", 5_000L, 2_990_000L),
            CoinStoreProduct("coins_10000", 10_000L, 3_490_000L),
            CoinStoreProduct("coins_20000", 20_000L, 4_890_000L),
            CoinStoreProduct("coins_50000", 50_000L, 6_490_000L)
        )

        fun find(productId: String): CoinStoreProduct? =
            all.firstOrNull { it.productId == productId }
    }
}

data class CoinPurchaseIntent(
    val payload: String,
    val productId: String,
    val coinAmount: Long,
    val expiresAtMillis: Long
)

data class CoinPurchaseConfirmation(
    val productId: String,
    val coinAmount: Long,
    val availableCoins: Long,
    val alreadyProcessed: Boolean
)
