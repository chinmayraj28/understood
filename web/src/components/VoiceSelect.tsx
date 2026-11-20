// "Hear it as": whose voice a recording is heard as. Your profiles first (the one in use marked),
// then, where it makes sense, the TORGO speakers, each set up from their own set-up clips.

import { useId } from "react";
import type { DatasetSpeaker } from "../../shared/dataset";
import { speakerDescription } from "../model/dataset";
import type { Profile } from "../storage/profiles";
import type { VoiceId } from "../useSession";

export function VoiceSelect(props: {
  value: VoiceId;
  onChange: (id: VoiceId) => void;
  profiles: Profile[];
  activeProfileId: string;
  /** TORGO speakers to offer as well. */
  speakers?: DatasetSpeaker[];
  /** An extra first option, such as a TORGO clip's own speaker. */
  first?: { value: VoiceId; label: string };
  label?: string;
}) {
  const id = useId();
  return (
    <label htmlFor={id} className="voice-select">
      <span>{props.label ?? "Hear it as"}</span>
      <select id={id} value={props.value} onChange={(e) => props.onChange(e.target.value)}>
        {props.first && <option value={props.first.value}>{props.first.label}</option>}
        <optgroup label="Your profiles">
          {props.profiles.map((p) => (
            <option key={p.id} value={`profile:${p.id}`}>
              {p.name}
              {p.id === props.activeProfileId ? " (in use)" : ""}
            </option>
          ))}
        </optgroup>
        {props.speakers && props.speakers.length > 0 && (
          <optgroup label="TORGO speakers">
            {props.speakers.map((s) => (
              <option key={s.id} value={`torgo:${s.id}`}>
                {s.id}: {speakerDescription(s)}
              </option>
            ))}
          </optgroup>
        )}
      </select>
    </label>
  );
}

/** A chosen voice that still exists, or the fallback: a deleted profile is never heard as. */
export function voiceStillThere(value: VoiceId | null, profiles: Profile[], fallback: VoiceId): VoiceId {
  if (!value) return fallback;
  if (value.startsWith("profile:")) return profiles.some((p) => `profile:${p.id}` === value) ? value : fallback;
  return value;
}
