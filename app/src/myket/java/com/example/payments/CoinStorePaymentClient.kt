package com.example.payments

import android.app.Activity
import androidx.activity.ComponentActivity
import com.example.BuildConfig
import com.example.data.model.CoinStoreProduct
import ir.myket.billingclient.IabHelper
import ir.myket.billingclient.util.IabResult
import ir.myket.billingclient.util.Inventory
import ir.myket.billingclient.util.Purchase
import java.io.IOException
import java.util.concurrent.CancellationException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Myket-only IAB client. The Myket SDK is included exclusively in the myket product flavor.
 * It never credits coins locally: signed receipt bytes are sent to SiteBin's Myket verifier.
 */
class CoinStorePaymentClient(private val activity: ComponentActivity) {
    private var helper: IabHelper? = null
    private var connected = false
    private var connecting = false
    private val connectionWaiters = mutableListOf<(Result<Unit>) -> Unit>()
    private val purchasesByToken = ConcurrentHashMap<String, Purchase>()

    fun ensureConnected(onResult: (Result<Unit>) -> Unit) {
        var startSetup = false
        var alreadyConnected = false
        synchronized(this) {
            if (connected) {
                alreadyConnected = true
            } else {
                connectionWaiters.add(onResult)
                if (!connecting) {
                    connecting = true
                    startSetup = true
                }
            }
        }
        if (alreadyConnected) {
            onResult(Result.success(Unit))
            return
        }
        if (!startSetup) return

        try {
            val newHelper = IabHelper(activity, BuildConfig.MYKET_RSA_PUBLIC_KEY)
            newHelper.enableDebugLogging(false)
            synchronized(this) { helper = newHelper }
            newHelper.startSetup { result ->
                if (result.isSuccess) {
                    completeConnection(Result.success(Unit))
                } else {
                    completeConnection(Result.failure(IOException("اتصال به فروشگاه مایکت برقرار نشد: $result")))
                }
            }
        } catch (error: Throwable) {
            completeConnection(Result.failure(error))
        }
    }

    private fun completeConnection(result: Result<Unit>) {
        val callbacks = synchronized(this) {
            connected = result.isSuccess
            connecting = false
            if (result.isFailure) {
                val failedHelper = helper
                helper = null
                runCatching { failedHelper?.dispose() }
            }
            connectionWaiters.toList().also { connectionWaiters.clear() }
        }
        callbacks.forEach { callback -> runCatching { callback(result) } }
    }

    fun purchase(
        productId: String,
        payload: String,
        onResult: (Result<CoinStoreReceipt>) -> Unit
    ) {
        if (CoinStoreProduct.find(productId) == null) {
            onResult(Result.failure(IllegalArgumentException("شناسه بسته سکه معتبر نیست.")))
            return
        }
        if (payload.isBlank() || payload.length > 128) {
            onResult(Result.failure(IllegalArgumentException("شناسه سفارش معتبر نیست.")))
            return
        }

        ensureConnected { connectionResult ->
            connectionResult.fold(
                onSuccess = {
                    val currentHelper = synchronized(this) { helper }
                    if (currentHelper == null) {
                        onResult(Result.failure(IOException("اتصال فروشگاه مایکت در دسترس نیست.")))
                        return@fold
                    }
                    val delivered = AtomicBoolean(false)
                    fun finish(result: Result<CoinStoreReceipt>) {
                        if (delivered.compareAndSet(false, true)) onResult(result)
                    }
                    try {
                        currentHelper.launchPurchaseFlow(
                            activity as Activity,
                            productId,
                            IabHelper.OnIabPurchaseFinishedListener { result, purchase ->
                                if (result.isFailure) {
                                    if (result.response == IabHelper.BILLING_RESPONSE_RESULT_USER_CANCELED) {
                                        finish(Result.failure(CancellationException("خرید توسط کاربر لغو شد.")))
                                    } else {
                                        finish(Result.failure(IOException("خرید از مایکت ناموفق بود: $result")))
                                    }
                                } else if (purchase == null) {
                                    finish(Result.failure(IOException("رسید خرید مایکت دریافت نشد.")))
                                } else {
                                    val token = purchase.token
                                    if (token.isNullOrBlank()) {
                                        finish(Result.failure(IOException("شناسه رسید خرید مایکت خالی است.")))
                                    } else {
                                        purchasesByToken[token] = purchase
                                        finish(Result.success(purchase.toCoinStoreReceipt()))
                                    }
                                }
                            },
                            payload
                        )
                    } catch (error: Throwable) {
                        finish(Result.failure(error))
                    }
                },
                onFailure = { error -> onResult(Result.failure(error)) }
            )
        }
    }

    fun queryPurchasedProducts(onResult: (Result<List<CoinStoreReceipt>>) -> Unit) {
        ensureConnected { connectionResult ->
            connectionResult.fold(
                onSuccess = {
                    val currentHelper = synchronized(this) { helper }
                    if (currentHelper == null) {
                        onResult(Result.failure(IOException("اتصال فروشگاه مایکت در دسترس نیست.")))
                        return@fold
                    }
                    try {
                        currentHelper.queryInventoryAsync(
                            false,
                            null,
                            IabHelper.QueryInventoryFinishedListener { result, inventory ->
                                if (result.isFailure) {
                                    onResult(Result.failure(IOException("بازیابی خریدهای مایکت ناموفق بود: $result")))
                                } else if (inventory == null) {
                                    onResult(Result.failure(IOException("فهرست خریدهای مایکت خالی است.")))
                                } else {
                                    val purchases = inventory.allPurchases.orEmpty()
                                    purchases.forEach { purchase ->
                                        val token = purchase.token
                                        if (!token.isNullOrBlank()) purchasesByToken[token] = purchase
                                    }
                                    onResult(Result.success(purchases.map { it.toCoinStoreReceipt() }))
                                }
                            }
                        )
                    } catch (error: Throwable) {
                        onResult(Result.failure(error))
                    }
                },
                onFailure = { error -> onResult(Result.failure(error)) }
            )
        }
    }

    fun consumeProduct(purchaseToken: String, onResult: (Result<Unit>) -> Unit) {
        if (purchaseToken.isBlank()) {
            onResult(Result.failure(IllegalArgumentException("شناسه رسید خرید خالی است.")))
            return
        }
        ensureConnected { connectionResult ->
            connectionResult.fold(
                onSuccess = {
                    val cached = purchasesByToken[purchaseToken]
                    if (cached != null) {
                        consume(cached, purchaseToken, onResult)
                    } else {
                        queryPurchasedProducts { queryResult ->
                            queryResult.fold(
                                onSuccess = { receipts ->
                                    val match = receipts.firstOrNull { it.purchaseToken == purchaseToken }
                                    val purchase = purchasesByToken[purchaseToken]
                                    if (match == null || purchase == null) {
                                        onResult(Result.failure(IOException("رسید تأییدشده در خریدهای بازیابی‌شده مایکت یافت نشد.")))
                                    } else {
                                        consume(purchase, purchaseToken, onResult)
                                    }
                                },
                                onFailure = { error -> onResult(Result.failure(error)) }
                            )
                        }
                    }
                },
                onFailure = { error -> onResult(Result.failure(error)) }
            )
        }
    }

    private fun consume(purchase: Purchase, token: String, onResult: (Result<Unit>) -> Unit) {
        val currentHelper = synchronized(this) { helper }
        if (currentHelper == null) {
            onResult(Result.failure(IOException("اتصال فروشگاه مایکت در دسترس نیست.")))
            return
        }
        val delivered = AtomicBoolean(false)
        fun finish(result: Result<Unit>) {
            if (delivered.compareAndSet(false, true)) {
                if (result.isSuccess) purchasesByToken.remove(token)
                onResult(result)
            }
        }
        try {
            currentHelper.consumeAsync(
                purchase,
                IabHelper.OnConsumeFinishedListener { _, result ->
                    if (result.isSuccess) finish(Result.success(Unit))
                    else finish(Result.failure(IOException("تکمیل رسید خرید مایکت ناموفق بود: $result")))
                }
            )
        } catch (error: Throwable) {
            finish(Result.failure(error))
        }
    }

    private fun Purchase.toCoinStoreReceipt(): CoinStoreReceipt = CoinStoreReceipt(
        productId = sku.orEmpty(),
        payload = developerPayload.orEmpty(),
        packageName = packageName.orEmpty(),
        originalJson = originalJson.orEmpty(),
        dataSignature = signature.orEmpty(),
        purchaseToken = token.orEmpty()
    )

    fun disconnect() {
        val currentHelper = synchronized(this) {
            connected = false
            connecting = false
            connectionWaiters.clear()
            helper.also { helper = null }
        }
        purchasesByToken.clear()
        runCatching { currentHelper?.dispose() }
    }
}
