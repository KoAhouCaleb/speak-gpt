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

package org.teslasoft.assistant.tools

import android.content.Context
import android.content.pm.PackageManager
import androidx.activity.result.ActivityResultCaller
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CompletableDeferred

/**
 * Suspending runtime permission requests for tool calls.
 *
 * Must be created before the caller (activity or fragment) is created, e.g. as a field initializer.
 * */
class ToolPermissionRequester(caller: ActivityResultCaller) {
    private var pending: CompletableDeferred<Unit>? = null

    private val launcher = caller.registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        pending?.complete(Unit)
        pending = null
    }

    suspend fun request(context: Context, permissions: Array<String>): Boolean {
        val missing = permissions.filter { !isGranted(context, it) }
        if (missing.isEmpty()) return true

        val deferred = CompletableDeferred<Unit>()
        pending?.complete(Unit)
        pending = deferred

        launcher.launch(missing.toTypedArray())
        deferred.await()

        return permissions.all { isGranted(context, it) }
    }

    private fun isGranted(context: Context, permission: String): Boolean {
        return ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
    }
}
