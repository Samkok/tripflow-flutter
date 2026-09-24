/// Where people get VoyZa — one place, so the update prompt, the share text
/// and the itinerary PDF can never drift apart.
library;

/// Country-neutral: Apple forwards to the visitor's own storefront.
const String voyzaAppStoreUrl = 'https://apps.apple.com/app/id6758559163';

const String voyzaPlayStoreUrl =
    'https://play.google.com/store/apps/details?id=com.superiordev.voyza';

/// For links that outlive the device that made them. An exported PDF is
/// opened on any phone or laptop, and a link inside it is one fixed address
/// — it can't pick a store for its reader. So it points at the website's
/// download section, which offers both stores. `ref=itinerary` lets the site
/// send phones straight into their own store (see landing/README.md); with
/// or without that rule the address resolves, so a document exported today
/// never carries a dead link.
const String voyzaGetAppUrl =
    'https://voyza.xtremon.com/?ref=itinerary#download';
