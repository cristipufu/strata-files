# Mermaid diagrams

This file contains five different diagram types. Each fenced block should appear as a diagram.

## 1. Flowchart

```mermaid
flowchart TD
    Start([Start]) --> Choose[Choose a folder]
    Choose --> Read[Read directory entries]
    Read --> Success{Read succeeded?}
    Success -->|Yes| List[Display files]
    Success -->|No| Error[Show an error]
    List --> Select[Select an item]
    Select --> Preview[Open preview]
    Preview --> Done([Done])
    Error --> Choose
```

## 2. Sequence diagram

```mermaid
sequenceDiagram
    autonumber
    participant User
    participant Browser
    participant Loader
    participant Preview
    User->>Browser: Select README.md
    User->>Browser: Press Space
    Browser->>Loader: Read Markdown
    Loader-->>Preview: Parsed document
    Preview->>Preview: Render diagrams
    Preview-->>User: Show document
    Note over User,Preview: All preview rendering happens locally
```

## 3. Class diagram

```mermaid
classDiagram
    class Browser {
        +location
        +selection
        +openPreview()
    }
    class Listing {
        +entries
        +sort()
    }
    class Preview {
        +document
        +findText()
    }
    Browser --> Listing : displays
    Browser --> Preview : opens
```

## 4. State diagram

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Loading: Open preview
    Loading --> Ready: Read succeeds
    Loading --> Failed: Read fails
    Loading --> Closed: Close window
    Ready --> Searching: Enter a query
    Searching --> Ready: Clear query
    Ready --> Closed: Close window
    Failed --> Loading: Try again
    Closed --> [*]
```

## 5. Pie chart

```mermaid
pie title Example folder contents
    "Documents" : 48
    "Images" : 27
    "Source code" : 18
    "Archives" : 7
```

## After the diagrams

This paragraph should still appear after the final diagram. Try resizing the window and changing the appearance while this file is open.
