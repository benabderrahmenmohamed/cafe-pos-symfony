import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useBackend } from '@/lib/backend-context';
import { queryKeys } from '@/lib/query';
import type { CategoryInput } from '@/ports';

export function useCategories() {
  const { catalog } = useBackend();
  return useQuery({
    queryKey: queryKeys.categories,
    queryFn: () => catalog.listCategories(),
  });
}

export function useCreateCategory() {
  const { catalog } = useBackend();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (input: CategoryInput) => catalog.createCategory(input),
    // A new category has no products yet - they link to it by id - so only its own list changes.
    // Not awaited: the save is done; the list refreshes in the background.
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.categories });
    },
  });
}

export function useDeleteCategory() {
  const { catalog } = useBackend();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => catalog.deleteCategory(id),
    // Products show their category, so both lists can change. Not awaited, as above.
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: queryKeys.categories });
      void queryClient.invalidateQueries({ queryKey: queryKeys.products });
    },
  });
}
