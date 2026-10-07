package com.grace.assistant.assist

import android.service.voice.VoiceInteractionService

/**
 * Registers Grace as a digital assistant. The system binds to it so that Grace can be
 * picked in Settings > Apps > Default apps > Digital assistant app. The work happens in
 * [GraceSession].
 */
class GraceInteractionService : VoiceInteractionService()
