package com.nxg.hermesagentmobile

import android.content.Context
import android.util.Log
import fi.iki.elonen.NanoHTTPD
import org.json.JSONObject
import java.io.File
import java.time.Instant

class ShizukuShellBridgeServer(
    private val context: Context,
    port: Int = BRIDGE_PORT,
) : NanoHTTPD("127.0.0.1", port) {

    companion object {
        private const val TAG = "ShizukuBridgeServer"
        const val BRIDGE_PORT = 18926
    }

    @Volatile
    private var lastErrorCode: String? = null

    @Volatile
    private var lastErrorMessage: String? = null

    private val bootstrapManager = BootstrapManager(
        context,
        context.filesDir.absolutePath,
        context.applicationInfo.nativeLibraryDir,
    )

    init {
        persistStatusSnapshot(currentStatusPayload())
    }

    override fun serve(session: IHTTPSession): Response {
        return try {
            when {
                session.method == Method.GET && session.uri == "/status" -> handleStatus()
                session.method == Method.POST && session.uri == "/enable" -> handleEnable(true)
                session.method == Method.POST && session.uri == "/disable" -> handleEnable(false)
                session.method == Method.POST && session.uri == "/exec" -> handleExec(session)
                else -> jsonResponse(
                    Response.Status.NOT_FOUND,
                    JSONObject().put("ok", false).put("error", "Not found"),
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "serve failed", e)
            jsonResponse(
                Response.Status.INTERNAL_ERROR,
                JSONObject().put("ok", false).put("error", e.message ?: "Internal error"),
            )
        }
    }

    fun statusMap(): Map<String, Any?> {
        return toMap(currentStatusPayload())
    }

    private fun handleStatus(): Response {
        val body = currentStatusPayload()
        persistStatusSnapshot(body)
        return jsonResponse(Response.Status.OK, body)
    }

    private fun handleEnable(enabled: Boolean): Response {
        ShizukuController.setBridgeEnabled(context, enabled)
        if (!enabled) {
            setLastError("bridge_disabled", "Shizuku bridge is disabled in settings")
        } else {
            clearLastError()
        }
        val body = currentStatusPayload().put("enabled", enabled)
        persistStatusSnapshot(body)
        return jsonResponse(Response.Status.OK, body)
    }

    private fun handleExec(session: IHTTPSession): Response {
        val files = HashMap<String, String>()
        session.parseBody(files)
        val raw = files["postData"] ?: ""
        val payload = if (raw.isBlank()) JSONObject() else JSONObject(raw)
        val command = payload.optString("command", "").trim()
        if (command.isEmpty()) {
            setLastError("invalid_command", "Missing command")
            val body = currentStatusPayload()
                .put("ok", false)
                .put("error_code", "invalid_command")
                .put("error", "Missing command")
            persistStatusSnapshot(currentStatusPayload())
            return jsonResponse(Response.Status.BAD_REQUEST, body)
        }

        if (!ShizukuController.isBridgeEnabled(context)) {
            setLastError("bridge_disabled", "Shizuku bridge is disabled in settings")
            val body = currentStatusPayload()
                .put("ok", false)
                .put("error_code", "bridge_disabled")
                .put("error", "Shizuku bridge is disabled in settings")
            persistStatusSnapshot(currentStatusPayload())
            return jsonResponse(Response.Status.FORBIDDEN, body)
        }

        val commandStatus = try {
            bootstrapManager.ensureShizukuBridgeScripts()
        } catch (e: Exception) {
            mapOf(
                "commandReady" to false,
                "commandError" to (e.message ?: "bridge_install_failed"),
            )
        }
        if (commandStatus["commandReady"] != true) {
            val errorMessage = (commandStatus["commandError"] as? String)
                ?: "system-shell wrapper commands are not ready"
            setLastError("command_unavailable", errorMessage)
            val body = currentStatusPayload()
                .put("ok", false)
                .put("error_code", "command_unavailable")
                .put("error", errorMessage)
            persistStatusSnapshot(currentStatusPayload())
            return jsonResponse(Response.Status.SERVICE_UNAVAILABLE, body)
        }

        val result = ShizukuController.executeShellCommand(command)
        if (result.success) {
            clearLastError()
        } else {
            setLastError(
                result.errorCode ?: "executor_missing",
                result.error ?: "Command execution failed",
            )
        }

        val body = JSONObject()
            .put("ok", result.success)
            .put("success", result.success)
            .put("exitCode", result.exitCode)
            .put("stdout", result.stdout)
            .put("stderr", result.stderr)
            .put("error_code", result.errorCode ?: JSONObject.NULL)

        if (result.error != null) {
            body.put("error", result.error)
        }

        persistStatusSnapshot(currentStatusPayload())
        return jsonResponse(Response.Status.OK, body)
    }

    private fun jsonResponse(status: Response.Status, json: JSONObject): Response {
        return newFixedLengthResponse(status, "application/json; charset=utf-8", json.toString())
    }

    private fun currentStatusPayload(): JSONObject {
        val commandStatus = try {
            bootstrapManager.ensureShizukuBridgeScripts()
        } catch (e: Exception) {
            mapOf(
                "commandReady" to false,
                "systemShellExists" to false,
                "statusCommandExists" to false,
                "systemShellPath" to "${context.filesDir.absolutePath}/rootfs/ubuntu/usr/local/bin/system-shell",
                "statusCommandPath" to "${context.filesDir.absolutePath}/rootfs/ubuntu/usr/local/bin/system-shell-status",
                "commandError" to (e.message ?: "bridge_install_failed"),
            )
        }
        val installed = ShizukuController.isShizukuAppInstalled(context)
        val running = ShizukuController.isServiceRunning()
        val permissionGranted = ShizukuController.hasPermission()
        val enabled = ShizukuController.isBridgeEnabled(context)
        val commandReady = commandStatus["commandReady"] == true
        val granted = permissionGranted && commandReady
        return JSONObject()
            .put("ok", installed && running && granted && enabled)
            .put("installed", installed)
            .put("running", running)
            .put("granted", granted)
            .put("permissionGranted", permissionGranted)
            .put("enabled", enabled)
            .put("commandReady", commandReady)
            .put("systemShellExists", commandStatus["systemShellExists"] == true)
            .put("statusCommandExists", commandStatus["statusCommandExists"] == true)
            .put("systemShellPath", commandStatus["systemShellPath"])
            .put("statusCommandPath", commandStatus["statusCommandPath"])
            .put("commandError", commandStatus["commandError"] ?: JSONObject.NULL)
            .put("executor", "system-shell")
            .put("bridge_port", BRIDGE_PORT)
            .put("last_error_code", lastErrorCode ?: JSONObject.NULL)
            .put("last_error", lastErrorMessage ?: JSONObject.NULL)
            .put("checked_at", Instant.now().toString())
    }

    private fun persistStatusSnapshot(payload: JSONObject) {
        try {
            val statusFile = File(context.filesDir, "home/.openclaw-android/capabilities/shizuku.json")
            statusFile.parentFile?.mkdirs()
            statusFile.writeText(payload.toString(2))
        } catch (e: Exception) {
            Log.w(TAG, "Failed writing Shizuku status snapshot: ${e.message}")
        }
    }

    private fun setLastError(code: String, message: String) {
        lastErrorCode = code
        lastErrorMessage = message
    }

    private fun clearLastError() {
        lastErrorCode = null
        lastErrorMessage = null
    }

    private fun toMap(obj: JSONObject): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        obj.keys().forEach { key ->
            map[key] = when (val value = obj.opt(key)) {
                JSONObject.NULL -> null
                is JSONObject -> toMap(value)
                else -> value
            }
        }
        return map
    }
}
