for s in 1 2 3 4 5 6 7 8; do
  echo "=== seed $s ==="
  python3 run.py --tier3 2000000 --seed $s || echo "LEADS on seed $s"
done

