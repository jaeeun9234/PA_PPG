package com.example.heartsync.data.model

/**
 * 앱 내부 표준 모델 (Firestore 직렬화용으로 map 변환해서 사용)
 */
data class PpgEvent(
    val event: String,                 // "STAT" | "ALERT"
    val host_time_iso: String,         // ISO8601
    val ts_ms: Long,                   // ESP32 부팅 이후 ms

    val smoothed_left: Double? = null,
    val smoothed_right: Double? = null,

    val alert_type: String? = null,    // e.g., "asymmetry"
    val reasons: List<String>? = null, // ["AmpRatio low","PAD high",...]

    val AmpRatio: Double? = null,
    val PAD_ms: Double? = null,
    val dSUT_ms: Double? = null,

    val ampL: Double? = null,
    val ampR: Double? = null,
    val AUSP_L: Double? = null,
    val AUSP_R: Double? = null,

    val SUTL_ms: Double? = null,
    val SUTR_ms: Double? = null,

    val BPM_L: Double? = null,
    val BPM_R: Double? = null,

    val PQIL: Int? = null,
    val PQIR: Int? = null,

    val side: String? = null,          // "left" | "right" | "balance"

    val AUSPR: Double? = null,
    val HSI: Double? = null,
    val risk: String? = null,
)

//fun PpgEvent.toMap(userId: String): Map<String, Any?> = mapOf(
//    "user_id" to userId,
//    "event" to event,
//    "host_time_iso" to host_time_iso,
//    "ts_ms" to ts_ms,
//    "alert_type" to alert_type,
//    "reasons" to reasons,
//
//    "AmpRatio" to AmpRatio,
//    "PAD_ms" to PAD_ms,
//    "dSUT_ms" to dSUT_ms,
//
//    "ampL" to ampL,
//    "ampR" to ampR,
//    "AUSP_L" to AUSP_L,
//    "AUSP_R" to AUSP_R,
//
//    "SUTL_ms" to SUTL_ms,
//    "SUTR_ms" to SUTR_ms,
//
//    "BPM_L" to BPM_L,
//    "BPM_R" to BPM_R,
//
//    "PQIL" to PQIL,
//    "PQIR" to PQIR,
//
//    "side" to side,
//    "smoothed_left" to smoothed_left,
//    "smoothed_right" to smoothed_right,
//
//    "AUSPR" to AUSPR,
//    "HSI" to HSI,
//    "risk" to risk,
//)
fun PpgEvent.toMap(userId: String): Map<String, Any> {
    fun MutableMap<String, Any>.putIfNotNull(k: String, v: Any?) {
        if (v != null) this[k] = v
    }
    return buildMap<String, Any> {
        this["user_id"] = userId
        this["event"] = event
        this["host_time_iso"] = host_time_iso
        this["ts_ms"] = ts_ms

        putIfNotNull("alert_type", alert_type)
        putIfNotNull("reasons", reasons)

        // ----- 여기부터는 전부 putIfNotNull 로만 넣기 -----
        putIfNotNull("AmpRatio", AmpRatio)
        putIfNotNull("ampL", ampL)
        putIfNotNull("ampR", ampR)
        putIfNotNull("AUSP_L", AUSP_L)
        putIfNotNull("AUSP_R", AUSP_R)
        putIfNotNull("SUTL_ms", SUTL_ms)
        putIfNotNull("SUTR_ms", SUTR_ms)
        putIfNotNull("BPM_L", BPM_L)
        putIfNotNull("BPM_R", BPM_R)
        putIfNotNull("PQIL", PQIL)
        putIfNotNull("PQIR", PQIR)
        putIfNotNull("side", side)
        putIfNotNull("smoothed_left", smoothed_left)
        putIfNotNull("smoothed_right", smoothed_right)

        putIfNotNull("AUSPR", AUSPR)
        putIfNotNull("PAD_ms", PAD_ms)
        putIfNotNull("HSI", HSI)
        putIfNotNull("risk", risk)

        // UI와 집계 코드가 PWTT 이름을 기대하는 곳이 있으니 별칭도 함께 저장
        if (PAD_ms != null) this["PWTT"] = PAD_ms!!
    }
}
