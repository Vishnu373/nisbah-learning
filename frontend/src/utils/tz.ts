/**
 * Converts a UTC time slot to the viewer's local timezone,
 * returning a display string with the teacher's original time in brackets.
 *
 * Example: "Mon 3:00 PM EST (originally 8:00 PM PKT)"
 */
export const formatAvailabilitySlot = (
  utcTime: string,
  teacherTz: string,
  viewerTz: string,
): string => {
  const [hours, minutes] = utcTime.split(':').map(Number);
  const base = new Date();
  base.setUTCHours(hours, minutes, 0, 0);

  const viewerFmt = new Intl.DateTimeFormat('en-US', {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: viewerTz,
    timeZoneName: 'short',
    weekday: 'short',
  }).format(base);

  const teacherFmt = new Intl.DateTimeFormat('en-US', {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: teacherTz,
    timeZoneName: 'short',
  }).format(base);

  return `${viewerFmt} (originally ${teacherFmt})`;
};
