import axios from 'axios';

const getContainers = () => {
   return axios.get(`/containers`, { timeout: 10000 })
      .then(response => response.data.data)
      .catch((e) => { console.error(e); });
};

// Shared by createReservationArgs (POST body) and formToQuery (URL query string) so
// the two serializations of the same form object can't drift apart.
const flattenValue = (v) => (
   (typeof(v) === 'boolean') ? (v ? 1 : 0) :
   ((typeof(v) === 'object') ? JSON.stringify(v) : v)
);

const createReservationArgs = (args) => {
   return Object.keys(args)
      .filter(k => args[k] !== undefined)
      .map(k => encodeURIComponent(k) + '=' + encodeURIComponent(flattenValue(args[k])))
      .join('&');
};

// Serialize a launch form to a Vue Router `query` object (plain string k/v pairs),
// so an in-progress launch can be reflected in and restored from the URL. Omits
// empty/default-ish values to keep the URL from ballooning with noise.
const formToQuery = (form) => {
   const query = {};
   Object.keys(form).forEach(k => {
      if (k === 'id') { return; } // irrelevant while prelaunching
      const v = form[k];
      if (v === undefined || v === null || v === '' || v === false) { return; }
      if (typeof v === 'object' && Object.keys(v).length === 0) { return; }
      query[k] = String(flattenValue(v));
   });
   return query;
};

const getReservationLogsUri = (args) => {
   return `/containers/${encodeURIComponent(args.id)}/logs?stdout=true&stderr=true&format=text&clean_pty=true&merge=true`;
};

// Container mutations now go over POST — no state-changing route is reachable via
// GET (GET is cacheable/prefetchable/logged). The body is the same form-encoded
// arg string the querystring used to carry, so the server still parses it raw with
// split_args (the reservation setters decode structured fields themselves): this is
// a transport-only change.
const FORM_POST = { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } };

const putContainer = (args) => {
   const url = args.id
      ? `/containers/${encodeURIComponent(args.id)}/update`
      : `/containers/create`;
   return axios.post(url, createReservationArgs(args), FORM_POST).then(response => response.data);
};

const controlContainer = (id, cmd) => {
   // Bodyless POST (start/stop/remove take no args).
   const url = `/containers/${encodeURIComponent(id)}/${encodeURIComponent(cmd)}`;
   return axios.post(url).then(response => response.data);
};

const getAuthCookies = () => {
   const url = `/getAuthCookies`;
   return axios.get(url).then(response => response.data);
};

export { getContainers, putContainer, controlContainer, getReservationLogsUri, getAuthCookies, formToQuery };
