import SwiftUI

struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        let left = rect.midX - 8 * unit
        let top = rect.midY - 8 * unit
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: left + x * unit, y: top + y * unit)
        }

        var path = Path()
        path.move(to: at(8, 0))
        for curve in stride(from: 0, to: GitHubMark.silhouette.count, by: 6) {
            path.addCurve(
                to: at(GitHubMark.silhouette[curve + 4], GitHubMark.silhouette[curve + 5]),
                control1: at(GitHubMark.silhouette[curve], GitHubMark.silhouette[curve + 1]),
                control2: at(GitHubMark.silhouette[curve + 2], GitHubMark.silhouette[curve + 3]))
        }
        path.closeSubpath()
        return path
    }

    private static let silhouette: [CGFloat] = [
        3.58, 0,        0, 3.58,        0, 8,
        0, 11.54,       2.29, 14.53,    5.47, 15.59,
        5.87, 15.66,    6.02, 15.42,    6.02, 15.21,
        6.02, 15.02,    6.01, 14.39,    6.01, 13.72,
        4, 14.09,       3.48, 13.23,    3.32, 12.78,
        3.23, 12.55,    2.84, 11.84,    2.5, 11.65,
        2.22, 11.5,     1.82, 11.13,    2.49, 11.12,
        3.12, 11.11,    3.57, 11.7,     3.72, 11.94,
        4.44, 13.15,    5.59, 12.81,    6.05, 12.6,
        6.12, 12.08,    6.33, 11.73,    6.56, 11.53,
        4.78, 11.33,    2.92, 10.64,    2.92, 7.58,
        2.92, 6.71,     3.23, 5.99,     3.74, 5.43,
        3.66, 5.23,     3.38, 4.41,     3.82, 3.31,
        3.82, 3.31,     4.49, 3.1,      6.02, 4.13,
        6.66, 3.95,     7.34, 3.86,     8.02, 3.86,
        8.7, 3.86,      9.38, 3.95,     10.02, 4.13,
        11.55, 3.09,    12.22, 3.31,    12.22, 3.31,
        12.66, 4.41,    12.38, 5.23,    12.3, 5.43,
        12.81, 5.99,    13.12, 6.7,     13.12, 7.58,
        13.12, 10.65,   11.25, 11.33,   9.47, 11.53,
        9.76, 11.78,    10.01, 12.26,   10.01, 13.01,
        10.01, 14.08,   10, 14.94,      10, 15.21,
        10, 15.42,      10.15, 15.67,   10.55, 15.59,
        13.8066, 14.4909, 15.9994, 11.4371, 16, 8,
        16, 3.58,       12.42, 0,       8, 0,
    ]
}
