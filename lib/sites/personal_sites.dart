/// Site definitions that are not in the shared registry.
///
/// Normally a site's configuration comes from the maintainer's registry at
/// `https://api.chance.surf/preferences/sites`, and the app offers whichever
/// entries that registry contains. A site whose *adapter* exists but whose
/// *config* has not been added to that registry is therefore implemented but
/// unreachable: it never appears in "Add new site", and `Settings.addSiteKey`
/// rejects it, because both consult the downloaded registry.
///
/// ylilauta.org is one of those, so its definition is kept here and merged over
/// the registry at runtime. Keeping it in a separate map makes the intent
/// obvious, and keeps it out of [defaultSites] (the shipped defaults).
///
/// Deleting this file and its three merge sites in `main.dart` removes ylilauta
/// without touching anything else.
const personalSites = <String, Map<String, Object?>>{
	'ylilauta': {
		'type': 'ylilauta',
		'name': 'ylilauta',
		'baseUrl': 'ylilauta.org',
		'defaultUsername': 'Anonyymi',
		'filesPerPost': 4
	}
};

/// The downloaded registry with [personalSites] layered over it.
///
/// Every place that needs to know which sites exist must use this rather than
/// reading `JsonCache.instance.sites` directly, otherwise a locally-defined site
/// is visible in some parts of the app and not others. The two that matter are
/// the "Add new site" dialog, which lists what it finds here, and
/// `Settings.addSiteKey`, which validates against it. `sites` may be null while
/// the registry has not downloaded yet, in which case only the local entries
/// exist.
Map<String, Map> availableSites(Map<String, Map>? sites) => {
	...sites ?? const <String, Map>{},
	...personalSites
};
