package com.example.payments

import androidx.activity.ComponentActivity
import com.example.data.model.CoinStoreProduct
import ir.cafebazaar.poolakey.Connection
import ir.cafebazaar.poolakey.Payment
import ir.cafebazaar.poolakey.config.PaymentConfiguration
import ir.cafebazaar.poolakey.entity.PurchaseInfo
import ir.cafebazaar.poolakey.request.PurchaseRequest
import ir.cafebazaar.poolakey.config.SecurityCheck
import java.util.concurrent.CancellationException
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Thin Poolakey wrapper. Financial credit is never granted by this class; it only returns
 * store-signed receipt data to the authenticated server for verification.
 */
class CoinStorePaymentClient(private val activity: ComponentActivity) {
    private val payment = Payment(
        context = activity,
        config = PaymentConfiguration(
            localSecurityCheck = SecurityCheck.Enable(rsaPublicKey = RSA_PUBLIC_KEY)
        )
    )

    private var connection: Connection? = null
    private var connected = false
    private var connecting = false
    private val connectionWaiters = mutableListOf<(Result<Unit>) -> Unit>()

    fun ensureConnected(onResult: (Result<Unit>) -> Unit) {
        var startConnection = false
        var alreadyConnected = false
        synchronized(this) {
            if (connected) {
                alreadyConnected = true
            } else {
                connectionWaiters.add(onResult)
                if (!connecting) {
                    connecting = true
                    startConnection = true
                }
            }
        }
        if (alreadyConnected) {
            onResult(Result.success(Unit))
            return
        }
        if (!startConnection) return

        try {
            val newConnection = payment.connect {
                connectionSucceed {
                    completeConnection(Result.success(Unit))
                }
                connectionFailed { throwable ->
                    completeConnection(Result.failure(throwable))
                }
                disconnected {
                    synchronized(this@CoinStorePaymentClient) {
                        connection = null
                    }
                    completeConnection(Result.failure(IOException("اتصال فروشگاه قطع شد.")))
                }
            }
            synchronized(this) {
                connection = newConnection
            }
        } catch (throwable: Throwable) {
            completeConnection(Result.failure(throwable))
        }
    }

    private fun completeConnection(result: Result<Unit>) {
        val callbacks = synchronized(this) {
            connected = result.isSuccess
            connecting = false
            if (!result.isSuccess) connection = null
            val pending = connectionWaiters.toList()
            connectionWaiters.clear()
            pending
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
                    val delivered = AtomicBoolean(false)
                    fun finish(result: Result<CoinStoreReceipt>) {
                        if (delivered.compareAndSet(false, true)) onResult(result)
                    }
                    try {
                        payment.purchaseProduct(
                            registry = activity.activityResultRegistry,
                            request = PurchaseRequest(
                                productId = productId,
                                payload = payload
                            )
                        ) {
                            purchaseSucceed { purchaseInfo ->
                                finish(Result.success(purchaseInfo.toCoinStoreReceipt()))
                            }
                            purchaseCanceled {
                                finish(Result.failure(CancellationException("خرید توسط کاربر لغو شد.")))
                            }
                            purchaseFailed { throwable ->
                                finish(Result.failure(throwable))
                            }
                            failedToBeginFlow { throwable ->
                                finish(Result.failure(throwable))
                            }
                        }
                    } catch (throwable: Throwable) {
                        finish(Result.failure(throwable))
                    }
                },
                onFailure = { throwable -> onResult(Result.failure(throwable)) }
            )
        }
    }

    fun queryPurchasedProducts(onResult: (Result<List<CoinStoreReceipt>>) -> Unit) {
        ensureConnected { connectionResult ->
            connectionResult.fold(
                onSuccess = {
                    try {
                        payment.getPurchasedProducts {
                            querySucceed { purchases -> onResult(Result.success(purchases.map { it.toCoinStoreReceipt() })) }
                            queryFailed { throwable -> onResult(Result.failure(throwable)) }
                        }
                    } catch (throwable: Throwable) {
                        onResult(Result.failure(throwable))
                    }
                },
                onFailure = { throwable -> onResult(Result.failure(throwable)) }
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
                    try {
                        payment.consumeProduct(purchaseToken) {
                            consumeSucceed { onResult(Result.success(Unit)) }
                            consumeFailed { throwable -> onResult(Result.failure(throwable)) }
                        }
                    } catch (throwable: Throwable) {
                        onResult(Result.failure(throwable))
                    }
                },
                onFailure = { throwable -> onResult(Result.failure(throwable)) }
            )
        }
    }

    private fun PurchaseInfo.toCoinStoreReceipt(): CoinStoreReceipt = CoinStoreReceipt(
        productId = productId,
        payload = payload,
        packageName = packageName,
        originalJson = originalJson,
        dataSignature = dataSignature,
        purchaseToken = purchaseToken
    )

    fun disconnect() {
        val current = synchronized(this) {
            connected = false
            connecting = false
            connectionWaiters.clear()
            connection.also { connection = null }
        }
        runCatching { current?.disconnect() }
    }

    private companion object {
        // This is the public verification key from the Cafe Bazaar developer panel.
        // It is not a private signing key. The server independently verifies each receipt.
        const val RSA_PUBLIC_KEY =
            "MIHNMA0GCSqGSIb3DQEBAQUAA4G7ADCBtwKBrwDWt5Y2sQisnbCWkRMPVo++g4KQOovvuvo+Cff8CikONTGU4SSuNSN3pTDqsP4c9lUpJ2kNfxtP938KsNF1QzvNzbnyXKKDtdAnBQIqQHeL+NIFXd0SZRfkwawHuNOEPFqp2C1/QUsHmSNIuufGXU8XQ0aWT93OpB/54EVojamCP9GhiOqJ+A06ciWF3NTjgEaHWFffG19PseuHi71ota35fLX4cbB4fJUgWK9VuAcCAwEAAQ=="
    }
}
