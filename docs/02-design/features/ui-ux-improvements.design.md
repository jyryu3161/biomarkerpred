# Design: UI/UX Improvements

> Ref: [Plan Document](../../01-plan/features/ui-ux-improvements.plan.md)

---

## 1. Feature 1: Score Threshold Helper Text

### 1.1 Current State

`AdvancedOptionsSection.tsx:399-415` — "Score Threshold" label + number input only. No explanation of what the value means.

### 1.2 Implementation

Add a `text-xs text-muted-foreground` helper text below the label. This approach is simpler and more discoverable than a tooltip (no hover required).

**Target location**: `AdvancedOptionsSection.tsx:401-403` (inside the label's parent div)

```tsx
{/* Score threshold */}
<div className="flex flex-col gap-1 max-w-xs">
  <label className="text-xs font-medium text-muted-foreground">
    Score Threshold
  </label>
  <p className="text-xs text-muted-foreground/70">
    Open Targets association score (0–1). Genes scoring ≥ this value are included.
  </p>
  <input
    type="number"
    value={evidenceScoreThreshold}
    ...
  />
</div>
```

### 1.3 Changes

| File | Lines | Change |
|------|-------|--------|
| `gui/src/components/setup/AdvancedOptionsSection.tsx` | 403-404 | Insert `<p>` helper text between label and input |

---

## 2. Feature 2: Select All / Deselect All for Quick Exclude

### 2.1 Current State

`FeatureSelectionAccordion.tsx:76-103` — Individual column toggle buttons only. No bulk operations.

### 2.2 Implementation

Add two small buttons ("Select All" / "Deselect All") next to the label in the Quick exclude section header.

**Logic**:
- **Select All**: Set `excludeFeatures` to union of current excludeFeatures + all availableColumns
- **Deselect All**: Remove all availableColumns from excludeFeatures (preserves manually-typed excludes not in availableColumns)

**Target location**: `FeatureSelectionAccordion.tsx:78-81` (label area)

```tsx
{availableColumns.length > 0 && (
  <div>
    <div className="flex items-center gap-2 mb-1">
      <label className="text-xs font-medium text-muted-foreground">
        Quick exclude columns from data
      </label>
      <button
        onClick={() => {
          setParam("excludeFeatures", [
            ...new Set([...excludeFeatures, ...availableColumns]),
          ]);
        }}
        className="px-1.5 py-0.5 text-[10px] rounded border border-border hover:bg-muted transition-colors text-muted-foreground"
      >
        Select All
      </button>
      <button
        onClick={() => {
          setParam(
            "excludeFeatures",
            excludeFeatures.filter((f) => !availableColumns.includes(f)),
          );
        }}
        className="px-1.5 py-0.5 text-[10px] rounded border border-border hover:bg-muted transition-colors text-muted-foreground"
      >
        Deselect All
      </button>
    </div>
    <div className="flex flex-wrap gap-1 max-h-24 overflow-y-auto">
      {availableColumns.map((col) => { ... })}
    </div>
  </div>
)}
```

### 2.3 Design Decisions

- **Two separate buttons** (not a toggle): Clearer UX — user always sees both options
- **Preserve manual excludes on Deselect All**: Only removes items present in `availableColumns`, so manually-typed genes remain in excludeFeatures
- **Button style**: `text-[10px]` small pills, consistent with existing muted UI style
- **No state tracking needed**: Select All / Deselect All derive from existing `excludeFeatures` and `availableColumns`

### 2.4 Changes

| File | Lines | Change |
|------|-------|--------|
| `gui/src/components/setup/FeatureSelectionAccordion.tsx` | 78-82 | Replace label-only div with flex row containing label + 2 buttons |

---

## 3. Implementation Order

1. `AdvancedOptionsSection.tsx` — Add helper text (1 line insert)
2. `FeatureSelectionAccordion.tsx` — Add Select All / Deselect All buttons (restructure label area)

## 4. Testing

- Manual: Verify helper text renders below Score Threshold label
- Manual: Select All marks all columns as excluded (red), Deselect All clears them
- Manual: Deselect All preserves manually-typed exclude genes not in availableColumns
- Manual: Buttons are visually consistent with existing UI
