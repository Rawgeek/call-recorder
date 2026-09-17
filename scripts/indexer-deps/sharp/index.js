// A stand-in for the image library @huggingface/transformers imports when it starts.
//
// That library requires sharp at import time and uses it only to read image and video input. Call
// Recorder embeds transcript text, so the real package, which brings libvips with it, is 15 MB
// the runtime never calls. Loading this file satisfies the import. Asking it to decode an image
// raises the fault below at the point of use, instead of failing where the import happened.
const unavailable = () => {
    throw new Error(
        "sharp is not part of the Call Recorder runtime; this build reads and writes text only",
    )
}

module.exports = unavailable
module.exports.default = unavailable
