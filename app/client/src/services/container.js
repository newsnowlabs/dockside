import axios from 'axios';

const getContainers = () => {
   return axios.get(`/containers`, { timeout: 10000 })
      .then(response => response.data.data)
      .catch((e) => { console.error(e); });
};

const createReservationArgs = (args) => {
   return Object.keys(args)
      .filter(k => args[k] !== undefined)
      .map(k => (
         encodeURIComponent(k) + '=' + 
         encodeURIComponent(
            (typeof(args[k]) === 'boolean') ? (args[k] ? 1 : 0) :
            ((typeof(args[k]) === 'object') ? JSON.stringify(args[k]) : args[k])
         )
      ))
      .join('&');
};

const createReservationUri = (args) => {
   return "/createContainerReservation/" + createReservationArgs(args);
};

const updateReservationUri = (args) => {
   return "/updateContainerReservation/" + createReservationArgs(args);
};

const getReservationLogsUri = (args) => {
   return `/containers/${args.id}/logs?stdout=true&stderr=true&format=text&clean_pty=true&merge=true`;
};

const putContainer = (args) => {
   const uri = args.id ? updateReservationUri(args) : createReservationUri(args);
   return axios.get(uri).then(response => response.data);
};

const controlContainer = (id, cmd) => {
   const url = `/${cmd}/` + encodeURIComponent(id);

   return axios.get(url).then(response => response.data);
};

export { getContainers, putContainer, controlContainer, createReservationUri, getReservationLogsUri };
