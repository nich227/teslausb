import { useContext, useEffect, useRef } from 'react';
import { ThemeContext } from '../theme';

export default function LogView({
  text,
  autoscroll = false,
}: {
  text: string;
  autoscroll?: boolean;
}) {
  const ref = useRef<HTMLPreElement>(null);
  const dark = useContext(ThemeContext);
  useEffect(() => {
    if (autoscroll && ref.current) ref.current.scrollTop = ref.current.scrollHeight;
  }, [text, autoscroll]);
  return (
    <pre
      ref={ref}
      style={{
        margin: 0,
        padding: '8px 10px',
        maxHeight: '70vh',
        overflow: 'auto',
        fontFamily: 'Monaco, Menlo, Consolas, monospace',
        fontSize: 12,
        lineHeight: 1.4,
        whiteSpace: 'pre',
        color: dark ? '#d6dbe1' : '#16191f',
        background: dark ? '#0f1620' : '#fafafa',
        border: `1px solid ${dark ? '#2a313a' : '#e9ebed'}`,
        borderRadius: 8,
      }}
    >
      {text}
    </pre>
  );
}
