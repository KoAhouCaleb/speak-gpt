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

package org.teslasoft.assistant.util

/**
 * Text helpers for speech synthesis: Markdown stripping and sentence splitting.
 * */
object SpeechText {

    private val FENCED_BLOCK = Regex("```[\\s\\S]*?(```|$)")
    private val IMAGE = Regex("!\\[([^\\]]*)]\\([^)]*\\)")
    private val LINK = Regex("\\[([^\\]]+)]\\([^)]*\\)")
    private val URL = Regex("https?://\\S+")
    private val HTML_TAG = Regex("</?[a-zA-Z][^>]*>")
    private val HEADING = Regex("(?m)^\\s{0,3}#{1,6}\\s*")
    private val BLOCKQUOTE = Regex("(?m)^\\s*(>\\s*)+")
    private val HORIZONTAL_RULE = Regex("(?m)^\\s*([-*_])(\\s*\\1){2,}\\s*$")
    private val TABLE_SEPARATOR = Regex("(?m)^\\s*\\|?\\s*:?-{2,}:?\\s*(\\|\\s*:?-{2,}:?\\s*)*\\|?\\s*$")
    private val LIST_MARKER = Regex("(?m)^\\s*([-*+]|\\d+[.)])\\s+")
    private val TASK_MARKER = Regex("(?m)^\\s*\\[[ xX]]\\s+")
    private val TABLE_PIPE = Regex("\\s*\\|\\s*")
    private val EMPHASIS = Regex("[*~]+")
    private val UNDERSCORE = Regex("(?<![\\p{L}\\p{N}])_+|_+(?![\\p{L}\\p{N}])")
    private val LATEX_DELIMITER = Regex("\\\\[()\\[\\]]")
    private val WHITESPACE = Regex("\\s+")
    private val EDGE_SEPARATORS = Regex("^[,\\s]+|[,\\s]+$")

    private val SENTENCE_END = setOf('.', '!', '?', '。', '！', '？')
    private val CLOSERS = setOf('"', '\'', ')', ']', '*', '_', '`', '”', '’')
    private val ABBREVIATIONS = setOf("mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs", "etc", "e.g", "i.e", "approx", "no", "fig")

    /**
     * Remove Markdown and other formatting so that only speakable text remains.
     *
     * @param text Markdown text.
     * @return Plain text, or an empty string when nothing speakable is left.
     * */
    fun sanitize(text: String): String {
        var s = text
        s = FENCED_BLOCK.replace(s, " ")
        s = IMAGE.replace(s) { it.groupValues[1] }
        s = LINK.replace(s) { it.groupValues[1] }
        s = URL.replace(s, " ")
        s = HTML_TAG.replace(s, " ")
        s = HORIZONTAL_RULE.replace(s, " ")
        s = TABLE_SEPARATOR.replace(s, " ")
        s = HEADING.replace(s, "")
        s = BLOCKQUOTE.replace(s, "")
        s = LIST_MARKER.replace(s, "")
        s = TASK_MARKER.replace(s, "")
        s = s.replace("`", "")
        s = TABLE_PIPE.replace(s, ", ")
        s = EMPHASIS.replace(s, "")
        s = UNDERSCORE.replace(s, "")
        s = LATEX_DELIMITER.replace(s, " ")
        s = WHITESPACE.replace(s, " ")
        s = EDGE_SEPARATORS.replace(s, "")

        return if (s.any { it.isLetterOrDigit() }) s else ""
    }

    /**
     * Incrementally splits a growing (streamed) response into sentences.
     *
     * Sentences end at a line break or at sentence punctuation followed by whitespace.
     * Fenced code blocks are never split, so they can be removed as a whole by [sanitize].
     * */
    class SentenceSplitter {
        private var text = ""
        private var consumed = 0

        /**
         * @param fullText The whole response received so far.
         * @return Sanitized sentences completed since the previous call.
         * */
        fun update(fullText: String): List<String> {
            // The response was rewritten (e.g. late </think> tag), start over
            if (consumed > fullText.length || !fullText.regionMatches(0, text, 0, consumed)) consumed = 0
            text = fullText

            val sentences = arrayListOf<String>()
            var start = consumed
            var inFence = false
            var i = consumed

            while (i < text.length) {
                if (text.startsWith("```", i)) {
                    inFence = !inFence
                    i += 3
                    continue
                }

                if (!inFence) {
                    val end = boundaryAt(i)
                    if (end != -1) {
                        add(sentences, text.substring(start, end))
                        start = end
                        i = end
                        continue
                    }
                }

                i++
            }

            consumed = start
            return sentences
        }

        /**
         * @param fullText The complete response.
         * @return Remaining sanitized sentences, including the unterminated tail.
         * */
        fun finish(fullText: String): List<String> {
            val sentences = ArrayList(update(fullText))
            add(sentences, text.substring(consumed))
            consumed = text.length
            return sentences
        }

        private fun add(sentences: MutableList<String>, chunk: String) {
            val clean = sanitize(chunk)
            if (clean.isNotEmpty()) sentences.add(clean)
        }

        /**
         * @return Exclusive end index of the sentence that ends at [i], or -1 if [i] is not a boundary.
         * */
        private fun boundaryAt(i: Int): Int {
            val c = text[i]
            if (c == '\n') return i + 1
            if (c !in SENTENCE_END) return -1

            var j = i + 1
            while (j < text.length && (text[j] in SENTENCE_END || text[j] in CLOSERS)) j++

            // Wait for the next character, the response may continue with "3.14" or "..."
            if (j >= text.length) return -1
            if (!text[j].isWhitespace()) return -1

            if (c == '.' && isNotSentenceEnd(i)) return -1

            return j
        }

        private fun isNotSentenceEnd(dot: Int): Boolean {
            var k = dot - 1
            while (k >= 0 && !text[k].isWhitespace()) k--
            val word = text.substring(k + 1, dot).trimStart('(', '"', '\'', '*', '_').lowercase()

            // "1. Item" list markers at the start of a line
            if (word.isNotEmpty() && word.all { it.isDigit() }) {
                val lineStart = text.lastIndexOf('\n', dot) + 1
                if (text.substring(lineStart, dot).trim() == word) return true
            }

            // Initials and common abbreviations ("J. Smith", "Dr. Who", "e.g. this")
            return (word.length == 1 && word[0].isLetter()) || word in ABBREVIATIONS
        }
    }
}
