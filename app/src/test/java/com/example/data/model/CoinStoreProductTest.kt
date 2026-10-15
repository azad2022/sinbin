package com.example.data.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class CoinStoreProductTest {
    @Test
    fun catalogContainsOnlyTheConfiguredProductsAndExactAmounts() {
        assertEquals(
            listOf(
                "coins_5000" to 5_000L,
                "coins_10000" to 10_000L,
                "coins_20000" to 20_000L,
                "coins_50000" to 50_000L
            ),
            CoinStoreProduct.all.map { it.productId to it.coinAmount }
        )
        assertEquals(
            listOf(2_990_000L, 3_490_000L, 4_890_000L, 6_490_000L),
            CoinStoreProduct.all.map { it.priceRial }
        )
        assertEquals(4, CoinStoreProduct.all.map { it.productId }.distinct().size)
    }

    @Test
    fun unknownProductsAreRejected() {
        assertNotNull(CoinStoreProduct.find("coins_5000"))
        assertNull(CoinStoreProduct.find("coins_999999"))
        assertNull(CoinStoreProduct.find(""))
    }
}
