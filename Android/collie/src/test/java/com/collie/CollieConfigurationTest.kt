package com.collie

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The configuration is the first of Collie's defence layers: it decides whether the
 * reporter installs at all. These tests mirror `CollieConfigurationTests.swift` so the two
 * platforms cannot drift on the fail-closed rules or on how endpoint URLs are built.
 */
class CollieConfigurationTest {

    private fun validConfig(
        baseUrl: String = "https://collie.example.com",
        apiKey: String = "test-key",
    ) = CollieConfiguration(enabled = true, apiBaseUrl = baseUrl, apiKey = apiKey)

    // MARK: - Flow defaults

    @Test
    fun `asksBeforeReporting defaults to true`() {
        assertTrue(validConfig().asksBeforeReporting)
    }

    @Test
    fun `asksBeforeReporting can be disabled`() {
        val config = CollieConfiguration(
            enabled = true,
            apiBaseUrl = "https://collie.example.com",
            apiKey = "test-key",
            asksBeforeReporting = false,
        )
        assertEquals(false, config.asksBeforeReporting)
    }

    @Test
    fun `activatesOnShake defaults to true`() {
        assertTrue(validConfig().activatesOnShake)
    }

    @Test
    fun `request timeout defaults to fifteen seconds`() {
        assertEquals(15_000L, validConfig().requestTimeoutMillis)
    }

    // MARK: - URLs

    @Test
    fun `reports url appends the default path`() {
        assertEquals(
            "https://collie.example.com/api/v1/collie/reports",
            validConfig().reportsUrl,
        )
    }

    @Test
    fun `reports url handles a trailing slash on the base`() {
        assertEquals(
            "https://collie.example.com/api/v1/collie/reports",
            validConfig(baseUrl = "https://collie.example.com/").reportsUrl,
        )
    }

    @Test
    fun `config url appends the default path`() {
        assertEquals(
            "https://collie.example.com/api/v1/collie/config",
            validConfig().configUrl,
        )
    }

    @Test
    fun `custom paths are honoured`() {
        val config = CollieConfiguration(
            enabled = true,
            apiBaseUrl = "https://collie.example.com",
            apiKey = "test-key",
            reportsPath = "custom/reports",
            configPath = "/custom/config",
        )
        assertEquals("https://collie.example.com/custom/reports", config.reportsUrl)
        assertEquals("https://collie.example.com/custom/config", config.configUrl)
    }

    // MARK: - Validation (fail-closed)

    @Test
    fun `a valid config has no validation error`() {
        assertNull(validConfig().validationError)
    }

    @Test
    fun `a missing api key fails validation`() {
        assertNotNull(validConfig(apiKey = "  ").validationError)
    }

    @Test
    fun `a base url without a host fails validation`() {
        assertNotNull(validConfig(baseUrl = "not-a-url").validationError)
    }

    @Test
    fun `a blank reports path fails validation`() {
        val config = CollieConfiguration(
            enabled = true,
            apiBaseUrl = "https://collie.example.com",
            apiKey = "test-key",
            reportsPath = " ",
        )
        assertNotNull(config.validationError)
    }

    @Test
    fun `a blank config path fails validation`() {
        val config = CollieConfiguration(
            enabled = true,
            apiBaseUrl = "https://collie.example.com",
            apiKey = "test-key",
            configPath = "",
        )
        assertNotNull(config.validationError)
    }

    // MARK: - Recursion prevention

    @Test
    fun `capture exclusion fragments are whole urls`() {
        val fragments = validConfig().captureExclusionFragments
        assertTrue(fragments.contains("https://collie.example.com/api/v1/collie/reports"))
        assertTrue(fragments.contains("https://collie.example.com/api/v1/collie/config"))
    }

    /**
     * The regression this property was rewritten for.
     *
     * Capture tools match the exclude list as substrings. While this returned the host and the
     * path separately, a short `reportsPath` matched the host app's own traffic: the entry
     * `/post` swallowed every `GET /posts` the app made, so reports arrived with an empty log
     * stream and nothing said why. The example app hit exactly this.
     */
    @Test
    fun `a short reports path does not exclude the host app's own traffic`() {
        val config = CollieConfiguration(
            enabled = true,
            apiBaseUrl = "https://collie.example.com",
            apiKey = "test-key",
            reportsPath = "/post",
        )
        val fragments = config.captureExclusionFragments
        val hostAppRequest = "https://api.example.com/v1/posts"

        assertTrue(
            "An unrelated request must not match any exclusion entry",
            fragments.none { hostAppRequest.contains(it) },
        )
        // Collie's own upload still matches, which is the whole point of the list.
        assertTrue(fragments.any { config.reportsUrl.contains(it) })
    }

    // MARK: - Clamping

    @Test
    fun `screenshot quality is clamped into the encoder's range`() {
        val tooHigh = CollieConfiguration(
            enabled = true,
            apiBaseUrl = "https://collie.example.com",
            apiKey = "k",
            screenshotJpegQuality = 5.0,
        )
        val tooLow = CollieConfiguration(
            enabled = true,
            apiBaseUrl = "https://collie.example.com",
            apiKey = "k",
            screenshotJpegQuality = -1.0,
        )
        assertEquals(1.0, tooHigh.effectiveJpegQuality, 0.0001)
        assertEquals(0.1, tooLow.effectiveJpegQuality, 0.0001)
    }

    @Test(expected = IllegalArgumentException::class)
    fun `a negative retry count is rejected`() {
        CollieConfiguration(
            enabled = true,
            apiBaseUrl = "https://collie.example.com",
            apiKey = "k",
            maxRetryCount = -1,
        )
    }
}
