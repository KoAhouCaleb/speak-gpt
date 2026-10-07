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

import android.annotation.SuppressLint
import android.app.Dialog
import android.content.Context
import android.graphics.drawable.Drawable
import android.os.Bundle
import android.text.Editable
import android.text.TextWatcher
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.util.TypedValue
import android.widget.EditText
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.DrawableCompat
import androidx.lifecycle.lifecycleScope
import com.google.android.material.bottomsheet.BottomSheetDialog
import com.google.android.material.bottomsheet.BottomSheetDialogFragment
import com.google.android.material.button.MaterialButton
import com.google.android.material.elevation.SurfaceColors
import com.google.android.material.textfield.TextInputLayout
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import org.teslasoft.assistant.R
import org.teslasoft.assistant.preferences.ApiEndpointPreferences
import org.teslasoft.assistant.preferences.Preferences
import org.teslasoft.assistant.util.ModelListClient

class AdvancedSettingsDialogFragment : BottomSheetDialogFragment() {
    companion object {
        fun newInstance(name: String, chatId: String) : AdvancedSettingsDialogFragment {
            val advancedSettingsDialogFragment = AdvancedSettingsDialogFragment()

            val args = Bundle()
            args.putString("name", name)
            args.putString("chatId", chatId)

            advancedSettingsDialogFragment.arguments = args

            return advancedSettingsDialogFragment
        }
    }

    private var radioGroup: RadioGroup? = null
    private var modelsStatus: TextView? = null
    // Buttons for models returned by the /models endpoint, keyed by model id
    private var modelButtons: LinkedHashMap<String, RadioButton> = linkedMapOf()
    private var see_all_models: RadioButton? = null
    private var see_favorite_models: RadioButton? = null
    private var ft: RadioButton? = null
    private var ftInput: EditText? = null
    private var maxTokens: EditText? = null
    private var endSeparator: EditText? = null
    private var prefix: EditText? = null
    private var ftFrame: TextInputLayout? = null
    private var temperatureSeekbar: com.google.android.material.slider.Slider? = null
    private var topPSeekbar: com.google.android.material.slider.Slider? = null
    private var frequencyPenaltySeekbar: com.google.android.material.slider.Slider? = null
    private var presencePenaltySeekbar: com.google.android.material.slider.Slider? = null
    private var btnSave: MaterialButton? = null
    private var btnCancel: MaterialButton? = null

    private var listener: StateChangesListener? = null

    private var model = "gpt-3.5-turbo"

    private var context: Context? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        context = this.activity
    }

    override fun onCreateView(inflater: LayoutInflater, container: ViewGroup?, savedInstanceState: Bundle?): View? {
        return inflater.inflate(R.layout.fragment_advanced_settings, container, false)
    }

    @SuppressLint("SetTextI18n")
    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)

        radioGroup = view.findViewById(R.id.radioGroup)
        modelsStatus = view.findViewById(R.id.models_status)
        see_all_models = view.findViewById(R.id.see_all_models)
        see_favorite_models = view.findViewById(R.id.see_favorite_models)
        ft = view.findViewById(R.id.ft)
        ftInput = view.findViewById(R.id.ft_input)
        maxTokens = view.findViewById(R.id.max_tokens)
        endSeparator = view.findViewById(R.id.end_separator)
        prefix = view.findViewById(R.id.prefix)
        ftFrame = view.findViewById(R.id.ft_frame)
        temperatureSeekbar = view.findViewById(R.id.temperature_slider)
        frequencyPenaltySeekbar = view.findViewById(R.id.frequency_penalty_slider)
        presencePenaltySeekbar = view.findViewById(R.id.presence_penalty_slider)
        topPSeekbar = view.findViewById(R.id.top_p_slider)
        btnSave = view.findViewById(R.id.btn_post)
        btnCancel = view.findViewById(R.id.btn_discard)

        val preferences: Preferences = Preferences.getPreferences(requireActivity(), arguments?.getString("chatId")!!)

        temperatureSeekbar?.value = preferences.getTemperature() * 10
        topPSeekbar?.value = preferences.getTopP() * 10
        frequencyPenaltySeekbar?.value = preferences.getFrequencyPenalty() * 10
        presencePenaltySeekbar?.value = preferences.getPresencePenalty() * 10

        temperatureSeekbar?.addOnChangeListener { _, value, _ ->
            preferences.setTemperature(value / 10.0f)
        }

        temperatureSeekbar?.setLabelFormatter {
            return@setLabelFormatter "${it/10.0}"
        }

        topPSeekbar?.addOnChangeListener { _, value, _ ->
            preferences.setTopP(value / 10.0f)
        }

        topPSeekbar?.setLabelFormatter {
            return@setLabelFormatter "${it/10.0}"
        }

        frequencyPenaltySeekbar?.addOnChangeListener { _, value, _ ->
            preferences.setFrequencyPenalty(value / 10.0f)
        }

        frequencyPenaltySeekbar?.setLabelFormatter {
            return@setLabelFormatter "${it/10.0}"
        }

        presencePenaltySeekbar?.addOnChangeListener { _, value, _ ->
            preferences.setPresencePenalty(value / 10.0f)
        }

        presencePenaltySeekbar?.setLabelFormatter {
            return@setLabelFormatter "${it/10.0}"
        }

        maxTokens?.setText(preferences.getMaxTokens().toString())
        endSeparator?.setText(preferences.getEndSeparator())
        prefix?.setText(preferences.getPrefix())

        ft?.setOnClickListener {
            setSelection(ft, ftInput?.text.toString(), hideFt = false, validateForm = false)
        }

        see_all_models?.setOnClickListener {
            val advancedModelSelectorDialogFragment = AdvancedModelSelectorDialogFragment.newInstance(model, requireArguments().getString("chatId").toString())
            advancedModelSelectorDialogFragment.setModelSelectedListener { model ->
                this@AdvancedSettingsDialogFragment.model = model

                reloadModelList(model)
                validateForm()
            }
            advancedModelSelectorDialogFragment.show(requireActivity().supportFragmentManager, "advancedModelSelectorDialogFragment")
        }

        see_favorite_models?.setOnClickListener {
            val advancedModelSelectorDialogFragment = AdvancedFavoriteModelSelectorDialogFragment.newInstance(model, requireArguments().getString("chatId").toString())
            advancedModelSelectorDialogFragment.setModelSelectedListener { model ->
                this@AdvancedSettingsDialogFragment.model = model

                reloadModelList(model)
                validateForm()
            }
            advancedModelSelectorDialogFragment.show(requireActivity().supportFragmentManager, "advancedFavoriteModelSelectorDialogFragment")
        }

        ftInput?.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) { /* unused */ }
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { model = s.toString() }
            override fun afterTextChanged(s: Editable?) { /* unused */ }
        })

        btnSave?.setOnClickListener {
            validateForm()
            Toast.makeText(requireActivity(), "Settings saved", Toast.LENGTH_SHORT).show()
        }

        btnCancel?.setOnClickListener {
            dismiss()
        }

        model = requireArguments().getString("name").toString()
        reloadModelList(model)
        loadModels(preferences)
    }

    private fun loadModels(preferences: Preferences) {
        val apiEndpointPreferences = ApiEndpointPreferences.getApiEndpointPreferences(requireActivity())
        val apiEndpoint = apiEndpointPreferences.getApiEndpoint(requireActivity(), preferences.getApiEndpointId())

        viewLifecycleOwner.lifecycleScope.launch {
            try {
                val models = ModelListClient.fetchTextModels(apiEndpoint.host, apiEndpoint.apiKey)

                if (models.isEmpty()) {
                    modelsStatus?.text = getString(R.string.label_no_models_found)
                    return@launch
                }

                populateModelButtons(models)
                modelsStatus?.visibility = View.GONE
                reloadModelList(model)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                modelsStatus?.text = getString(R.string.msg_model_loading_error_with_details) + e.message.toString()
            }
        }
    }

    private fun populateModelButtons(models: List<String>) {
        val group = radioGroup ?: return
        val status = modelsStatus ?: return

        modelButtons.values.forEach { group.removeView(it) }
        modelButtons.clear()

        val insertAt = group.indexOfChild(status) + 1

        models.forEachIndexed { index, id ->
            val button = RadioButton(requireActivity())
            button.setButtonDrawable(null)
            button.minHeight = dp(56)
            button.setPadding(dp(16), 0, dp(16), 0)
            button.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            button.text = id

            val params = RadioGroup.LayoutParams(RadioGroup.LayoutParams.MATCH_PARENT, RadioGroup.LayoutParams.WRAP_CONTENT)
            params.marginStart = dp(24)
            params.marginEnd = dp(24)
            params.topMargin = if (index == 0) dp(24) else dp(2)

            group.addView(button, insertAt + index, params)
            bindClickListener(button, id)
            modelButtons[id] = button
        }
    }

    private fun dp(value: Int) : Int {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value.toFloat(), resources.displayMetrics).toInt()
    }

    override fun onCreateDialog(savedInstanceState: Bundle?): Dialog {
        return BottomSheetDialog(requireContext(), R.style.ThemeOverlay_App_BottomSheetDialog)
    }

    private fun reloadModelList(model: String) {
        val button = modelButtons[model]

        if (button != null) {
            setSelection(button, null, hideFt = true, validateForm = false)
        } else { // model is not in the fetched list (or the list is not loaded yet)
            setSelection(ft, model, hideFt = false, validateForm = false)
            ftInput?.setText(model)
        }
    }

    private fun bindClickListener(view: RadioButton?, value: String?) {
        view?.setOnClickListener {
            setSelection(view, value)
        }
    }

    private fun setSelection(view: RadioButton?, value: String?, hideFt: Boolean = true, validateForm: Boolean = true) {
        clearSelection()
        clearSelection()
        view?.setTextColor(ContextCompat.getColor(requireActivity(), R.color.window_background))
        view?.background = getDarkAccentDrawableV2(
            ContextCompat.getDrawable(requireActivity(), R.drawable.btn_accent)!!)
        if (value != null) model = value
        if (hideFt) ftFrame?.visibility = View.GONE else ftFrame?.visibility = View.VISIBLE
        if (validateForm) validateForm()
    }

    private fun clearSingleSelection(view: RadioButton?, isTop: Boolean = false, isBottom: Boolean = false) {
        var background = R.drawable.btn_accent_center
        if (isTop && isBottom) background = R.drawable.btn_accent
        else if (isTop) background = R.drawable.btn_accent_top
        else if (isBottom) background = R.drawable.btn_accent_bottom
        view?.background = getDarkAccentDrawable(
            ContextCompat.getDrawable(requireActivity(), background)!!, requireActivity())
        view?.setTextColor(ContextCompat.getColor(requireActivity(), R.color.neutral_200))
    }

    private fun clearSelection() {
        val buttons = modelButtons.values.toList()
        buttons.forEachIndexed { index, button ->
            clearSingleSelection(button, isTop = index == 0, isBottom = index == buttons.lastIndex)
        }
        clearSingleSelection(ft, isBottom = true)
        clearSingleSelection(see_all_models)
        clearSingleSelection(see_favorite_models, isTop = true)
    }

    private fun getDarkAccentDrawable(drawable: Drawable, context: Context) : Drawable {
        DrawableCompat.setTint(DrawableCompat.wrap(drawable), getSurfaceColor(context))
        return drawable
    }

    private fun getDarkAccentDrawableV2(drawable: Drawable) : Drawable {
        DrawableCompat.setTint(DrawableCompat.wrap(drawable), getSurfaceColorV2())
        return drawable
    }

    private fun getSurfaceColor(context: Context) : Int {
        return SurfaceColors.SURFACE_3.getColor(context)
    }

    private fun getSurfaceColorV2() : Int {
        return requireActivity().getColor(R.color.accent_900)
    }

    private fun validateForm() {
        if (ftInput?.text.toString() == "" && ft?.isChecked == true) {
            listener!!.onFormError(model, maxTokens?.text.toString(), endSeparator?.text.toString(), prefix?.text.toString())
            return
        }

        listener!!.onSelected(model, maxTokens?.text.toString(), endSeparator?.text.toString(), prefix?.text.toString())
    }

    fun setStateChangedListener(listener: StateChangesListener) {
        this.listener = listener
    }

    interface StateChangesListener {
        fun onSelected(name: String, maxTokens: String, endSeparator: String, prefix: String)
        fun onFormError(name: String, maxTokens: String, endSeparator: String, prefix: String)
    }
}
