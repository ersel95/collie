package com.collie.example

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

data class Post(val id: Int, val title: String, val body: String)

/**
 * A thin API client over the shared [OkHttpClient] — the same client both Chucker and
 * Collie's bridge are attached to, which is what makes the traffic show up in both.
 *
 * It talks to jsonplaceholder, a public fake API, so the example needs no backend of its own.
 */
class PostsApi(private val client: OkHttpClient) {

    suspend fun posts(): List<Post> = withContext(Dispatchers.IO) {
        val request = Request.Builder().url("$BASE_URL/posts?_limit=8").build()
        client.newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) error("HTTP ${response.code}")
            val array = JSONArray(body)
            (0 until array.length()).map { index ->
                val item = array.getJSONObject(index)
                Post(
                    id = item.getInt("id"),
                    title = item.getString("title"),
                    body = item.getString("body"),
                )
            }
        }
    }

    suspend fun createPost(title: String, body: String): Int = withContext(Dispatchers.IO) {
        val payload = JSONObject()
            .put("title", title)
            .put("body", body)
            .put("userId", 1)
            .toString()

        val request = Request.Builder()
            .url("$BASE_URL/posts")
            .post(payload.toRequestBody("application/json".toMediaType()))
            .build()

        client.newCall(request).execute().use { response ->
            val responseBody = response.body?.string().orEmpty()
            if (!response.isSuccessful) error("HTTP ${response.code}")
            JSONObject(responseBody).optInt("id", -1)
        }
    }

    /**
     * The bug. A 404 that the app surfaces as a useless message — the situation a tester
     * reports, and the request an analyst needs to see in the report to understand it.
     */
    suspend fun brokenCall(): Int = withContext(Dispatchers.IO) {
        val request = Request.Builder().url("$BASE_URL/posts/does-not-exist").build()
        client.newCall(request).execute().use { response -> response.code }
    }

    private companion object {
        const val BASE_URL = "https://jsonplaceholder.typicode.com"
    }
}
