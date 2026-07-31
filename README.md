# Octoryn Swift SDK

Native Swift 6 SDK for governed Octoryn text generation, streaming, tool calls,
JSON Schema structured output, and SwiftUI chat state.

```swift
let client = try OctorynClient(apiKey: token)
let result = try await client.generateText(
    .init(model: "policy/frontier", prompt: "Summarise this")
)
```

`OctorynCore` never executes an agent loop. Use Reef for multi-step tool and
approval workflows. `OctorynSwiftUI` is a native UI-state layer and does not
embed a JavaScript runtime.
