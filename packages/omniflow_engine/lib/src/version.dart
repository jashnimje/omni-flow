const String omniflowEngineVersion = '1.0.0';

/// The release build number, the commit count of the tagged commit. The
/// release workflow writes it here before it builds, so it has to stay on
/// one line in this form. A local build is 0.
const int omniflowBuild = 0;

/// `1.0.0 (build 40)`, or only the version in a local build.
String get omniflowVersionLabel => omniflowBuild > 0
    ? '$omniflowEngineVersion (build $omniflowBuild)'
    : omniflowEngineVersion;
