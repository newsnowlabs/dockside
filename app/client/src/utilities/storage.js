// The client's settings in browser storage (localStorage), read and written so
// that a browser refusing storage - blocked by the user or a policy, a private
// window, an exhausted quota - never stops the client. In some browsers merely
// reading window.localStorage throws when storage is blocked, so that access is
// inside the try as well. A read that fails returns null, as a missing key
// does; a write that fails is dropped, so the setting lasts for this page only.

export function readSetting(key) {
   try {
      return window.localStorage.getItem(key);
   }
   catch (e) {
      return null;
   }
}

export function writeSetting(key, value) {
   try {
      window.localStorage.setItem(key, String(value));
   }
   catch (e) {
      // Dropped: see above.
   }
}
