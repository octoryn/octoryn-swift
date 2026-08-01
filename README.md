# Octoryn Swift SDK

Native Swift 6 SDK for governed Octoryn text generation, streaming, tool calls,
JSON Schema structured output, and SwiftUI chat state.

Add `https://github.com/octoryn/octoryn-swift` as a Swift Package dependency
from version `0.2.1`, then link `OctorynCore` and, for native chat state,
`OctorynSwiftUI`.

```swift
let client = try OctorynClient(apiKey: token)
let result = try await client.generateText(
    .init(model: "openai/gpt-4.1-mini", prompt: "Summarise this")
)
```

`OctorynCore` never executes an agent loop or claims an agent API on the
Router. `OctorynSwiftUI` is a native UI-state layer and does not embed a
JavaScript runtime.

`OctorynChat` supports edit and regenerate. A custom native
`OctorynChatTransport` may attach stable event IDs; interrupted streams then
expose `canResume`, `lastEventID` and `resume()`. The default OpenAI-compatible
stream does not claim cursor recovery because that wire protocol has no
resume cursor.
