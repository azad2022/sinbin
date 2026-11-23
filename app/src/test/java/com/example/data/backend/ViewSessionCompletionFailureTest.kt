package com.example.data.backend

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ViewSessionCompletionFailureTest {
    @Test
    fun sessionExpiredCodeBecomesAnActionableTypedFailure() {
        val failure = viewCompletionFailure("SESSION_EXPIRED")

        assertTrue(failure is ViewSessionExpiredException)
        assertEquals(
            "مهلت سشن بازدید در سرور تمام شده است؛ این بازدید ثبت نشده. برای ادامه یک بازدید جدید شروع کنید.",
            failure.message
        )
    }

    @Test
    fun unknownCompletionFailureRemainsFailClosed() {
        val failure = viewCompletionFailure("UNEXPECTED_ERROR")

        assertTrue(failure !is ViewSessionExpiredException)
        assertEquals("خطا در تایید سرور برای بازدید.", failure.message)
    }
}
