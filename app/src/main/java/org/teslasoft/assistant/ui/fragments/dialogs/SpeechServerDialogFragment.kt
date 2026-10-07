/**************************************************************************
 * Copyright (c) 2023-2026 Dmytro Ostapenko. All rights reserved.
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

package org.teslasoft.assistant.ui.fragments.dialogs

import android.app.Dialog
import android.os.Bundle
import android.view.View
import android.widget.TextView
import android.widget.Toast
import androidx.fragment.app.DialogFragment
import androidx.lifecycle.lifecycleScope
import com.google.android.material.button.MaterialButton
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.teslasoft.assistant.R
import org.teslasoft.assistant.preferences.SpeechServerPreferences
import org.teslasoft.assistant.util.SpeechServerClient

/**
 * Configure a self-hosted OpenAI-compatible speech server (STT or TTS).
 * */
class SpeechServerDialogFragment : DialogFragment() {
    companion object {
        fun newInstance(type: String) : SpeechServerDialogFragment {
            val fragment = SpeechServerDialogFragment()

            val args = Bundle()
            args.putString("type", type)

            fragment.arguments = args

            return fragment
        }
    }

    private var switchEnabled: MaterialSwitch? = null
    private var fieldHost: TextInputEditText? = null
    private var fieldApiKey: TextInputEditText? = null
    private var fieldModel: TextInputEditText? = null
    private var fieldExtra: TextInputEditText? = null

    private var listener: OnSavedListener? = null

    private val type: String
        get() = requireArguments().getString("type") ?: SpeechServerPreferences.TYPE_STT

    override fun onCreateDialog(savedInstanceState: Bundle?): Dialog {
        val view: View = layoutInflater.inflate(R.layout.fragment_speech_server, null)

        val title: TextView = view.findViewById(R.id.text_dialog_title)
        val note: TextView = view.findViewById(R.id.text_note)
        val layoutExtra: TextInputLayout = view.findViewById(R.id.layout_extra)
        val btnFetchVoices: MaterialButton = view.findViewById(R.id.btn_fetch_voices)

        switchEnabled = view.findViewById(R.id.switch_enabled)
        fieldHost = view.findViewById(R.id.field_host)
        fieldApiKey = view.findViewById(R.id.field_api_key)
        fieldModel = view.findViewById(R.id.field_model)
        fieldExtra = view.findViewById(R.id.field_extra)

        val config = SpeechServerPreferences.getSpeechServerPreferences(requireContext()).getConfig(type)

        switchEnabled?.isChecked = config.enabled
        fieldHost?.setText(config.host.ifBlank { SpeechServerPreferences.defaultHost(type) })
        fieldApiKey?.setText(config.apiKey)
        fieldModel?.setText(config.model)

        if (type == SpeechServerPreferences.TYPE_TTS) {
            title.text = getString(R.string.label_speech_server_tts)
            note.text = getString(R.string.msg_speech_server_tts_note)
            layoutExtra.hint = getString(R.string.label_speech_server_voice)
            fieldExtra?.hint = null
            fieldExtra?.setText(config.voice)
            btnFetchVoices.visibility = View.VISIBLE
            btnFetchVoices.setOnClickListener { fetchVoices() }
        } else {
            title.text = getString(R.string.label_speech_server_stt)
            note.text = getString(R.string.msg_speech_server_stt_note)
            fieldExtra?.setText(config.language)
        }

        return MaterialAlertDialogBuilder(requireContext(), R.style.App_MaterialAlertDialog)
            .setView(view)
            .setPositiveButton(R.string.btn_save) { _, _ -> save() }
            .setNegativeButton(R.string.btn_cancel) { _, _ -> }
            .create()
    }

    private fun currentConfig(): SpeechServerPreferences.Config {
        val extra = fieldExtra?.text?.toString() ?: ""

        return SpeechServerPreferences.Config(
            enabled = switchEnabled?.isChecked == true,
            host = fieldHost?.text?.toString() ?: "",
            apiKey = fieldApiKey?.text?.toString() ?: "",
            model = fieldModel?.text?.toString() ?: "",
            voice = if (type == SpeechServerPreferences.TYPE_TTS) extra else "af_heart",
            language = if (type == SpeechServerPreferences.TYPE_STT) extra else ""
        )
    }

    private fun save() {
        val config = currentConfig()
        val context = context ?: return

        if (config.enabled && config.host.isBlank()) {
            Toast.makeText(context, R.string.msg_speech_server_host_empty, Toast.LENGTH_SHORT).show()
            return
        }

        SpeechServerPreferences.getSpeechServerPreferences(context).setConfig(type, config)
        listener?.onSaved(type, config)
    }

    private fun fetchVoices() {
        val config = currentConfig()
        val activity = activity ?: return

        activity.lifecycleScope.launch {
            try {
                val voices = withContext(Dispatchers.IO) { SpeechServerClient.listVoices(config) }

                if (voices.isEmpty()) {
                    Toast.makeText(activity, R.string.msg_speech_server_no_voices, Toast.LENGTH_SHORT).show()
                    return@launch
                }

                MaterialAlertDialogBuilder(activity, R.style.App_MaterialAlertDialog)
                    .setTitle(R.string.label_speech_server_voice)
                    .setItems(voices.toTypedArray()) { _, which -> fieldExtra?.setText(voices[which]) }
                    .setNegativeButton(R.string.btn_cancel) { _, _ -> }
                    .show()
            } catch (e: Exception) {
                Toast.makeText(activity, getString(R.string.msg_speech_server_error) + " " + (e.message ?: ""), Toast.LENGTH_LONG).show()
            }
        }
    }

    fun setOnSavedListener(listener: OnSavedListener) {
        this.listener = listener
    }

    fun interface OnSavedListener {
        fun onSaved(type: String, config: SpeechServerPreferences.Config)
    }
}
