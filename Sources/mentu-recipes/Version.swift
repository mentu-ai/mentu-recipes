/// The release version this binary reports. `release.yml` refuses to build a
/// tag whose name does not match this string, so a published binary always
/// answers `mentu-recipes --version` with the tag it was built from.
enum MentuRecipesVersion {
    static let string = "0.2.2"
}
