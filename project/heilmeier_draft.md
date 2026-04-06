Heilmeier Questions

1. What are you trying to do? Articulate your objectives using absolutely no jargon.

I want to improve speed for a common AI calculation by designing a small custom computer chip just for that calculation. The slowest (most demanding) parts of this calculation will be identified, and the custom chip will be optimized for these specific parts.

2. How is it done today, and what are the limits of current practice?

Currently the transformer algorithm uses NumPy in python and runs on a general purpose CPU. Data is reloaded many times and relies on cache for movement. The number of multiplication operations occuring at once is also limited.

3. What is new in your approach and why do you think it will be succesful?

The new approach is to allow for multiple multiplication operations at once (parallelization) and also move compute closer to memory on the chip. Increasing parallelization and reducing required time for data transfer between compute and memory should decrease time required to run that calculation.
