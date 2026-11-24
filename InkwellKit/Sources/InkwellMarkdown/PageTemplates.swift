import Foundation

/// Starting points for a new page: Markdown with page elements, plus any front matter the page needs.
public enum PageTemplate: String, CaseIterable, Sendable, Identifiable {
    case blank, about, now, contact, projects, links, timeline, places, landing, archive, albums, slides

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blank: localized("Blank")
        case .about: localized("About")
        case .now: localized("Now")
        case .contact: localized("Contact")
        case .projects: localized("Projects")
        case .links: localized("Links")
        case .timeline: localized("Timeline")
        case .places: localized("Places")
        case .landing: localized("Landing Page")
        case .archive: localized("Archive")
        case .albums: localized("Photo Albums")
        case .slides: localized("Slides")
        }
    }

    public var summary: String {
        switch self {
        case .blank: localized("An empty page.")
        case .about: localized("Who you are, with a picture and a few links.")
        case .now: localized("What you are doing these days.")
        case .contact: localized("How to reach you.")
        case .projects: localized("Your work as cards with pictures.")
        case .links: localized("A column of buttons to your other places.")
        case .timeline: localized("Your story or CV as dated steps.")
        case .places: localized("A map of places you have been.")
        case .landing: localized("A banner, three columns and a button.")
        case .archive: localized("Every post, by year.")
        case .albums: localized("All your photo albums.")
        case .slides: localized("A presentation: each section break is a slide.")
        }
    }

    public var symbol: String {
        switch self {
        case .blank: "doc"
        case .about: "person.crop.circle"
        case .now: "clock"
        case .contact: "envelope"
        case .projects: "rectangle.grid.2x2"
        case .links: "link"
        case .timeline: "point.topleft.down.to.point.bottomright.curvepath"
        case .places: "map"
        case .landing: "rectangle.3.group"
        case .archive: "archivebox"
        case .albums: "photo.stack"
        case .slides: "play.rectangle"
        }
    }

    /// The title a new page of this kind starts with.
    public var suggestedTitle: String {
        switch self {
        case .blank, .landing: ""
        case .albums: localized("Albums")
        default: title
        }
    }

    /// Front matter beyond `layout` and `title`.
    public var fields: [(String, String)] {
        switch self {
        case .landing: [("hide_title", "true"), ("wide", "true")]
        case .projects, .places, .albums: [("wide", "true")]
        default: []
        }
    }

    /// A layout other than the site's page layout.
    public var layout: String? { self == .slides ? "slides" : nil }

    public func body(collection: String = "posts", today: Date = Date()) -> String {
        let el = { (kind: PageElement) in kind.template(collection: collection) }
        switch self {
        case .blank:
            return "\n"
        case .about:
            return """

            \(localized("Hello. Write a few sentences about who you are and what this site is for."))

            <div class="ik-columns" markdown="1">
            <div markdown="1">
            ## \(localized("What I do"))
            \(localized("A short paragraph about your work."))
            </div>
            <div markdown="1">
            ## \(localized("Elsewhere"))
            \(PageElement.social.template())
            </div>
            </div>

            """
        case .now:
            let date = today.formatted(.dateTime.year().month(.wide).day())
            return """

            *\(localized("Updated \(date)"))*

            ## \(localized("Working on"))
            - \(localized("Something you are making"))

            ## \(localized("Reading"))
            - \(localized("A book"))

            ## \(localized("Thinking about"))
            - \(localized("An idea"))

            """
        case .contact:
            return """

            \(localized("The best way to reach me is by email."))

            <a class="ik-button" href="mailto:you@example.com">\(localized("Send an Email"))</a>

            \(el(.social))

            """
        case .projects:
            return """

            \(localized("Things I have made."))

            <div class="ik-cards" markdown="1">
            - **[\(localized("First project"))](/)**
              \(localized("What it is, in a sentence."))
            - **[\(localized("Second project"))](/)**
              \(localized("What it is, in a sentence."))
            - **[\(localized("Third project"))](/)**
              \(localized("What it is, in a sentence."))
            </div>

            """
        case .links:
            return """

            \(localized("Find me here."))

            <a class="ik-button" href="{{ '/' | relative_url }}">\(localized("My writing"))</a>

            <a class="ik-button ik-button--outline" href="mailto:you@example.com">\(localized("Email"))</a>

            <a class="ik-button ik-button--outline" href="https://github.com/">GitHub</a>

            """
        case .timeline:
            return "\n\(localized("How I got here."))\n\n\(el(.timeline))\n"
        case .places:
            return "\n\(localized("Places I have been. Add them with Edit on the map."))\n\n\(el(.map))\n"
        case .landing:
            return """

            \(el(.hero))

            <div class="ik-columns" markdown="1">
            <div markdown="1">
            ### \(localized("Write"))
            \(localized("A sentence about the first thing."))
            </div>
            <div markdown="1">
            ### \(localized("Make"))
            \(localized("A sentence about the second thing."))
            </div>
            <div markdown="1">
            ### \(localized("Share"))
            \(localized("A sentence about the third thing."))
            </div>
            </div>

            \(el(.recent))

            \(el(.button))

            """
        case .archive:
            return "\n\(el(.archive))\n"
        case .albums:
            return "\n{% include inkwell/albums.html %}\n"
        case .slides:
            return """

            # \(localized("A title for the talk"))
            \(localized("Your name"))

            ***

            ## \(localized("The first point"))
            - \(localized("One thing"))
            - \(localized("Another thing"))

            ***

            ## \(localized("Thank you"))

            """
        }
    }
}
