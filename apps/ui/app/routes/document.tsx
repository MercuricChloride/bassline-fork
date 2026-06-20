import { Container, Paper, Stack, Title } from '@mantine/core'
import { read } from '@bassline/core/text'
import baseDoc from '../../public/document.blt?raw'
import { DocumentView } from '../view/hooks'

const examples = import.meta.glob('../../public/examples/*.blt', {
  query: '?raw',
  import: 'default',
  eager: true,
}) as Record<string, string>

export function meta() {
  return [{ title: 'Bassline documents' }]
}

const name = (path: string) =>
  path
    .split('/')
    .pop()!
    .replace(/\.blt$/, '')

export default function DocumentRoute() {
  const docs: Array<[string, string]> = [
    ['document', baseDoc],
    ...Object.entries(examples).map(
      ([p, s]) => [name(p), s] as [string, string]
    ),
  ]
  return (
    <Container py="xl" size="md">
      <Stack gap="xl">
        {docs.map(([n, src]) => (
          <Stack key={n} gap="xs">
            <Title order={4} c="dimmed">
              {n}.blt
            </Title>
            <Paper withBorder p="md" radius="md">
              <DocumentView doc={read(src)[0]} />
            </Paper>
          </Stack>
        ))}
      </Stack>
    </Container>
  )
}
