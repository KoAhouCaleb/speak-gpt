/**************************************************************************
 * Copyright (c) 2026 Caleb Hall. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **************************************************************************/

package org.teslasoft.assistant.assist

import android.service.voice.VoiceInteractionService

/**
 * Registers SpeakGPT as a full digital assistant. Unlike a plain ACTION_ASSIST activity,
 * a voice interaction service receives the screenshot and on-screen text
 * when the assistant is invoked (if allowed in the system assist settings).
 * */
class AssistInteractionService : VoiceInteractionService()
