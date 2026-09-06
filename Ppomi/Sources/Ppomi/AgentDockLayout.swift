import CoreGraphics

/// Geometry only: a native conversation window must fit beside the device without covering controls.
/// All rectangles use the same unflipped AppKit coordinate space (top is maxY), in logical points.
/// Window sizes include their own title bar/chrome; resizing lets that app reflow, never scales a screenshot.
enum AgentDockLayout {
    /// Use the whole sidebar with explicit reservations, or an already reserved workbenchArea with
    /// approvalHeight = 0. A zero reservation adds no gap. The native size is preserved when it fits;
    /// otherwise each dimension is reduced only as far as the app's known minimum permits.
    static func frame(in column: CGRect, naturalSize: CGSize, minimumSize: CGSize,
                      headerHeight: CGFloat = 0, approvalHeight: CGFloat = 0,
                      gap: CGFloat = 12) -> CGRect? {
        guard valid(naturalSize), valid(minimumSize),
              let available = availableRect(in: column, headerHeight: headerHeight,
                                            approvalHeight: approvalHeight, gap: gap),
              minimumSize.width <= available.width, minimumSize.height <= available.height else { return nil }
        let size = CGSize(width: min(available.width, max(naturalSize.width, minimumSize.width)),
                          height: min(available.height, max(naturalSize.height, minimumSize.height)))
        // Top alignment keeps the external app's toolbar next to Ppomi's conversation/records selector.
        return CGRect(x: available.minX + (available.width - size.width) / 2,
                      y: available.maxY - size.height, width: size.width, height: size.height)
    }

    /// Recheck after AX resize: apps may clamp the requested dimensions to a larger native minimum.
    /// False means do not place the companion over the header or approval band; hide/clear its slot instead.
    /// This checks capacity only. The caller must still position and verify the native window's actual origin.
    static func accepts(actualSize: CGSize, in column: CGRect,
                        headerHeight: CGFloat = 0, approvalHeight: CGFloat = 0,
                        gap: CGFloat = 12) -> Bool {
        frame(in: column, naturalSize: actualSize, minimumSize: actualSize,
              headerHeight: headerHeight, approvalHeight: approvalHeight, gap: gap) != nil
    }

    /// This does not choose a sidebar or move the selected device. It only subtracts reserved control bands.
    static func availableRect(in column: CGRect, headerHeight: CGFloat = 0,
                              approvalHeight: CGFloat = 0, gap: CGFloat = 12) -> CGRect? {
        guard !column.isNull, !column.isInfinite, !column.isEmpty,
              valid(column.size), column.origin.x.isFinite, column.origin.y.isFinite,
              column.maxX.isFinite, column.maxY.isFinite,
              [headerHeight, approvalHeight, gap].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let top = headerHeight + (headerHeight > 0 ? gap : 0)
        let bottom = approvalHeight + (approvalHeight > 0 ? gap : 0)
        let height = column.height - top - bottom
        guard height.isFinite, height > 0 else { return nil }
        let available = CGRect(x: column.minX, y: column.minY + bottom,
                               width: column.width, height: height)
        guard available.origin.y.isFinite, available.maxY.isFinite else { return nil }
        return available
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
