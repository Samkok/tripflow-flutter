-- request_country(): the country this request's connection comes from.
--
-- The app decides whether analytics and ads measurement need an opt-in from
-- two signals: the country the device is set to, and the country the
-- connection comes from. A phone set to "United States" says nothing about
-- where it is; a traveller in Paris is in France. This function supplies the
-- second signal.
--
-- It reads the country code the network edge (Cloudflare) attaches to every
-- API request and returns it. Nothing is stored: no address, no row, no log
-- entry of ours. 'XX' (unknown) and 'T1' (Tor) come back as they are; the
-- app treats anything that is not a country as "cannot tell".
--
-- Outside an API request (a migration, the SQL editor) there are no request
-- headers and the function returns NULL.
CREATE OR REPLACE FUNCTION public.request_country()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT nullif(
    upper(trim(
      nullif(current_setting('request.headers', true), '')::json ->> 'cf-ipcountry'
    )),
    ''
  );
$$;

REVOKE ALL ON FUNCTION public.request_country() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_country() TO anon, authenticated;

COMMENT ON FUNCTION public.request_country() IS
  'Two-letter country of the calling connection, from the edge''s cf-ipcountry header. Stores nothing. Used by the app to decide whether measurement needs an opt-in.';
